import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Code Chunk Model

struct CodeChunk: Codable {
    // Identity
    let id: String                  // file:line hash
    let file: String                // relative path
    let line: Int
    let endLine: Int
    let name: String                // function/type name
    let kind: ChunkKind
    
    // Hierarchy
    let parentType: String?         // containing class/struct
    let modulePath: String          // e.g., "Account/Auth"
    
    // Signature
    let signature: String           // full declaration
    let parameters: [String]        // parameter names
    let returnType: String?
    
    // Documentation
    let docComment: String?
    let purpose: String?            // inferred or from doc
    
    // Relationships
    let calls: [String]             // methods this calls
    let calledBy: [String]          // methods that call this (filled later)
    let usesTypes: [String]         // types referenced
    let conformsTo: [String]        // protocols (for types)
    
    // Metrics
    let complexity: Int?  // nil for types (only applies to functions)
    let lineCount: Int
    let visibility: Visibility
    
    // Indicators
    let isSingleton: Bool
    let hasSmells: Bool
    let hasTodo: Bool
    
    // Domain keywords (extracted from names, strings, comments)
    let keywords: [String]
    
    // Architecture
    let layer: String              // ui, network, persistence, business-logic (from path/type)
    let imports: [String]          // actual imports (reveals layer violations)
    let patterns: [String]         // async-await, callback, throws, delegate, singleton, rx-observable
    
    // The formatted text for embedding
    var embeddingText: String {
        var parts: [String] = []
        
        // Header: Type.Name in Path
        if let parent = parentType {
            parts.append("\(parent).\(name) in \(modulePath)")
        } else {
            parts.append("\(name) in \(modulePath)")
        }
        
        // Purpose (from doc or inferred)
        if let purpose = purpose ?? docComment {
            parts.append("Purpose: \(purpose)")
        }
        
        // Signature
        parts.append("Signature: \(signature)")
        
        // Calls (if any)
        if !calls.isEmpty {
            parts.append("Calls: \(calls.prefix(10).joined(separator: ", "))")
        }
        
        // Called by (if any)
        if !calledBy.isEmpty {
            parts.append("Called by: \(calledBy.prefix(10).joined(separator: ", "))")
        }
        
        // Domain keywords
        if !keywords.isEmpty {
            parts.append("Domain: \(keywords.joined(separator: ", "))")
        }
        
        // Architecture
        parts.append("Layer: \(layer)")
        if !imports.isEmpty {
            parts.append("Uses: \(imports.joined(separator: ", "))")
        }
        if !patterns.isEmpty {
            parts.append("Patterns: \(patterns.joined(separator: ", "))")
        }
        
        // Metrics
        if let complexity = complexity {
            parts.append("Complexity: \(complexity), Lines: \(lineCount)")
        } else {
            parts.append("Lines: \(lineCount)")
        }
        
        return parts.joined(separator: "\n")
    }
    
    enum ChunkKind: String, Codable {
        case function
        case method
        case initializer
        case property
        case `class`
        case `struct`
        case `enum`
        case `protocol`
        case `extension`
    }
    
    enum Visibility: String, Codable {
        case `public`
        case `internal`
        case `private`
        case `fileprivate`
        case `open`
    }
}

// MARK: - File Findings (from existing analyzers)

struct FileFindings {
    var singletonLines: Set<Int> = []
    var reactiveLines: Set<Int> = []
    var networkLines: Set<Int> = []
    var delegateLines: Set<Int> = []
    
    func hasPattern(_ pattern: PatternType, inRange startLine: Int, endLine: Int) -> Bool {
        let lines: Set<Int>
        switch pattern {
        case .singleton: lines = singletonLines
        case .reactive: lines = reactiveLines
        case .network: lines = networkLines
        case .delegate: lines = delegateLines
        }
        return lines.contains { $0 >= startLine && $0 <= endLine }
    }
    
    enum PatternType {
        case singleton, reactive, network, delegate
    }
}

// MARK: - Chunk Extractor

class ChunkExtractor {
    
    func extractChunks(from parsedFiles: [ParsedFile]) -> [CodeChunk] {
        // Step 1: Pre-compute findings using existing visitors (reuses parsed ASTs)
        var findingsByFile: [String: FileFindings] = [:]
        
        for file in parsedFiles {
            var findings = FileFindings()
            
            // Singleton analysis (uses FileAnalyzer)
            let singletonVisitor = FileAnalyzer(filePath: file.relativePath, sourceText: file.sourceText)
            singletonVisitor.walk(file.ast)
            findings.singletonLines = Set(singletonVisitor.references.compactMap { $0.line })
            
            // Reactive analysis (RxSwift/Combine)
            let reactiveVisitor = ReactiveVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            reactiveVisitor.walk(file.ast)
            findings.reactiveLines = Set(reactiveVisitor.subscriptions.compactMap { $0.line })
            
            // Network analysis
            let networkVisitor = NetworkVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            networkVisitor.walk(file.ast)
            findings.networkLines = Set(networkVisitor.endpoints.compactMap { $0.line })
            
            // Delegate analysis
            let delegateVisitor = DelegateWiringVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            delegateVisitor.walk(file.ast)
            findings.delegateLines = Set(delegateVisitor.wirings.compactMap { $0.line })
            
            findingsByFile[file.relativePath] = findings
        }
        
        // Step 2: Extract chunks with enriched patterns
        var allChunks: [CodeChunk] = []
        var callGraph: [String: Set<String>] = [:]
        
        for file in parsedFiles {
            let imports = extractImports(from: file.ast)
            let findings = findingsByFile[file.relativePath] ?? FileFindings()
            
            let visitor = ChunkVisitor(
                filePath: file.relativePath,
                sourceText: file.sourceText,
                imports: imports,
                findings: findings
            )
            visitor.walk(file.ast)
            allChunks.append(contentsOf: visitor.chunks)
            
            // Collect call relationships
            for chunk in visitor.chunks {
                let callerId = "\(chunk.parentType ?? "").\(chunk.name)"
                callGraph[callerId] = Set(chunk.calls)
            }
        }
        
        // Second pass: fill in "calledBy" relationships
        var calledByMap: [String: [String]] = [:]
        for (caller, callees) in callGraph {
            for callee in callees {
                calledByMap[callee, default: []].append(caller)
            }
        }
        
        // Update chunks with calledBy
        allChunks = allChunks.map { chunk in
            var updated = chunk
            let chunkId = "\(chunk.parentType ?? "").\(chunk.name)"
            // Use reflection/rebuild since structs are immutable
            return CodeChunk(
                id: chunk.id,
                file: chunk.file,
                line: chunk.line,
                endLine: chunk.endLine,
                name: chunk.name,
                kind: chunk.kind,
                parentType: chunk.parentType,
                modulePath: chunk.modulePath,
                signature: chunk.signature,
                parameters: chunk.parameters,
                returnType: chunk.returnType,
                docComment: chunk.docComment,
                purpose: chunk.purpose,
                calls: chunk.calls,
                calledBy: calledByMap[chunkId] ?? [],
                usesTypes: chunk.usesTypes,
                conformsTo: chunk.conformsTo,
                complexity: chunk.complexity,
                lineCount: chunk.lineCount,
                visibility: chunk.visibility,
                isSingleton: chunk.isSingleton,
                hasSmells: chunk.hasSmells,
                hasTodo: chunk.hasTodo,
                keywords: chunk.keywords,
                layer: chunk.layer,
                imports: chunk.imports,
                patterns: chunk.patterns
            )
        }
        
        return allChunks
    }
    
    private func extractImports(from ast: SourceFileSyntax) -> [String] {
        var imports: [String] = []
        for statement in ast.statements {
            if let importDecl = statement.item.as(ImportDeclSyntax.self) {
                let moduleName = importDecl.path.description.trimmingCharacters(in: .whitespaces)
                imports.append(moduleName)
            }
        }
        return imports
    }
}

// MARK: - Chunk Visitor

final class ChunkVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    let imports: [String]
    let layer: String
    let findings: FileFindings
    
    private(set) var chunks: [CodeChunk] = []
    
    private var currentType: String?
    private var currentTypeKind: CodeChunk.ChunkKind?
    
    init(filePath: String, sourceText: String, imports: [String], findings: FileFindings) {
        self.filePath = filePath
        self.sourceText = sourceText
        self.imports = imports
        self.findings = findings
        // Layer is inferred per-chunk based on path + type name (not imports)
        self.layer = "business-logic"  // Default, will be overridden per chunk
        super.init(viewMode: .sourceAccurate)
    }
    
    /// Infer layer for a specific chunk (uses path + type name)
    private func inferLayerForChunk(typeName: String?) -> String {
        return Self.inferLayer(filePath: filePath, typeName: typeName)
    }
    
    // MARK: - Layer Inference (path-based, not import-based)
    
    private static func inferLayer(filePath: String, typeName: String?) -> String {
        let path = filePath.lowercased()
        
        // Priority 1: Path-based signals (strongest)
        if path.contains("/network/") || path.contains("/api/") || path.contains("/service") {
            return "network"
        }
        if path.contains("/view/") || path.contains("/controller/") || path.contains("/ui/") {
            return "ui"
        }
        if path.contains("/storage/") || path.contains("/persistence/") || path.contains("/cache/") || path.contains("/keychain") {
            return "persistence"
        }
        if path.contains("/model/") || path.contains("/entity/") || path.contains("/domain/") {
            return "domain"
        }
        
        // Priority 2: Type name signals (medium)
        if let name = typeName {
            if name.hasSuffix("ViewController") || name.hasSuffix("View") || name.hasSuffix("Cell") {
                return "ui"
            }
            if name.hasSuffix("Service") || name.hasSuffix("API") || name.contains("Network") {
                return "network"
            }
            if name.hasSuffix("Storage") || name.hasSuffix("Repository") || name.contains("Keychain") {
                return "persistence"
            }
        }
        
        // Default: business logic
        return "business-logic"
    }
    
    // MARK: - Pattern Detection
    
    private func detectPatterns(signature: String, bodyText: String, hasThrows: Bool, startLine: Int, endLine: Int) -> [String] {
        var patterns: [String] = []
        
        // Async/await (from signature/body)
        if signature.contains("async") || bodyText.contains("await ") {
            patterns.append("async-await")
        }
        
        // Throws (from signature)
        if hasThrows {
            patterns.append("throws")
        }
        
        // Callback pattern (from signature)
        if signature.contains("completion") || signature.contains("handler") || signature.contains("callback") {
            patterns.append("callback")
        }
        
        // Delegate (from DelegateAnalyzer)
        if findings.hasPattern(.delegate, inRange: startLine, endLine: endLine) {
            patterns.append("delegate")
        }
        
        // RxSwift/Combine (from ReactiveAnalyzer)
        if findings.hasPattern(.reactive, inRange: startLine, endLine: endLine) {
            patterns.append("reactive")
        }
        
        // Singleton usage (from FileAnalyzer/singleton analysis)
        if findings.hasPattern(.singleton, inRange: startLine, endLine: endLine) {
            patterns.append("uses-singleton")
        }
        
        // Network calls (from NetworkAnalyzer)
        if findings.hasPattern(.network, inRange: startLine, endLine: endLine) {
            patterns.append("network-call")
        }
        
        return patterns
    }
    
    // MARK: - Type declarations
    
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        currentType = name
        currentTypeKind = .class
        
        let chunk = makeTypeChunk(
            name: name,
            kind: .class,
            node: node,
            inheritanceClause: node.inheritanceClause,
            modifiers: node.modifiers
        )
        chunks.append(chunk)
        
        return .visitChildren
    }
    
    override func visitPost(_ node: ClassDeclSyntax) {
        currentType = nil
        currentTypeKind = nil
    }
    
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        currentType = name
        currentTypeKind = .struct
        
        let chunk = makeTypeChunk(
            name: name,
            kind: .struct,
            node: node,
            inheritanceClause: node.inheritanceClause,
            modifiers: node.modifiers
        )
        chunks.append(chunk)
        
        return .visitChildren
    }
    
    override func visitPost(_ node: StructDeclSyntax) {
        currentType = nil
        currentTypeKind = nil
    }
    
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        currentType = name
        currentTypeKind = .enum
        
        let chunk = makeTypeChunk(
            name: name,
            kind: .enum,
            node: node,
            inheritanceClause: node.inheritanceClause,
            modifiers: node.modifiers
        )
        chunks.append(chunk)
        
        return .visitChildren
    }
    
    override func visitPost(_ node: EnumDeclSyntax) {
        currentType = nil
        currentTypeKind = nil
    }
    
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        currentType = name
        currentTypeKind = .protocol
        
        let chunk = makeTypeChunk(
            name: name,
            kind: .protocol,
            node: node,
            inheritanceClause: node.inheritanceClause,
            modifiers: node.modifiers
        )
        chunks.append(chunk)
        
        return .visitChildren
    }
    
    override func visitPost(_ node: ProtocolDeclSyntax) {
        currentType = nil
        currentTypeKind = nil
    }
    
    // MARK: - Function declarations
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let chunk = makeFunctionChunk(node: node)
        chunks.append(chunk)
        return .skipChildren  // Don't recurse into nested functions for now
    }
    
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let chunk = makeInitializerChunk(node: node)
        chunks.append(chunk)
        return .skipChildren
    }
    
    // MARK: - Helpers
    
    private func makeTypeChunk(
        name: String,
        kind: CodeChunk.ChunkKind,
        node: some SyntaxProtocol,
        inheritanceClause: InheritanceClauseSyntax?,
        modifiers: DeclModifierListSyntax
    ) -> CodeChunk {
        let startLine = lineNumber(for: node.position) ?? 1
        let endLine = lineNumber(for: node.endPosition) ?? startLine
        
        // Extract protocols/inheritance
        var conformsTo: [String] = []
        if let inheritance = inheritanceClause {
            conformsTo = inheritance.inheritedTypes.map { 
                $0.type.description.trimmingCharacters(in: .whitespaces) 
            }
        }
        
        // Extract visibility
        let visibility = extractVisibility(from: modifiers)
        
        // Extract doc comment
        let docComment = extractDocComment(for: node)
        
        // Check for singleton pattern
        let nodeText = node.description
        let isSingleton = nodeText.contains(".shared") || 
                         nodeText.contains("sharedInstance") ||
                         nodeText.contains("static let shared")
        
        // Extract keywords from name
        let keywords = extractKeywords(from: name)
        
        // Module path from file
        let modulePath = extractModulePath(from: filePath)
        
        return CodeChunk(
            id: "\(filePath):\(startLine)",
            file: filePath,
            line: startLine,
            endLine: endLine,
            name: name,
            kind: kind,
            parentType: nil,
            modulePath: modulePath,
            signature: "\(kind.rawValue) \(name)",
            parameters: [],
            returnType: nil,
            docComment: docComment,
            purpose: nil,
            calls: [],
            calledBy: [],
            usesTypes: conformsTo,
            conformsTo: conformsTo,
            complexity: nil,  // Types don't have cyclomatic complexity
            lineCount: endLine - startLine + 1,
            visibility: visibility,
            isSingleton: isSingleton,
            hasSmells: false,
            hasTodo: nodeText.contains("TODO") || nodeText.contains("FIXME"),
            keywords: keywords,
            layer: inferLayerForChunk(typeName: name),
            imports: imports,
            patterns: isSingleton ? ["singleton"] : []
        )
    }
    
    private func makeFunctionChunk(node: FunctionDeclSyntax) -> CodeChunk {
        let name = node.name.text
        let startLine = lineNumber(for: node.position) ?? 1
        let endLine = lineNumber(for: node.endPosition) ?? startLine
        
        // Extract parameters
        let parameters = node.signature.parameterClause.parameters.map { param in
            param.firstName.text
        }
        
        // Extract return type
        let returnType = node.signature.returnClause?.type.description
            .trimmingCharacters(in: .whitespaces)
        
        // Build signature
        let signature = "func \(name)(\(parameters.joined(separator: ":") + (parameters.isEmpty ? "" : ":")))" +
                       (returnType != nil ? " -> \(returnType!)" : "")
        
        // Extract visibility
        let visibility = extractVisibility(from: node.modifiers)
        
        // Extract doc comment
        let docComment = extractDocComment(for: node)
        
        // Extract method calls from body
        var calls: [String] = []
        var usesTypes: [String] = []
        if let body = node.body {
            let callVisitor = CallExtractorVisitor()
            callVisitor.walk(body)
            calls = callVisitor.calls
            usesTypes = callVisitor.types
        }
        
        // Calculate complexity using proper AST visitor
        var complexity = 1  // Base complexity
        if let body = node.body {
            let complexityVisitor = ComplexityVisitor(viewMode: .sourceAccurate)
            complexityVisitor.walk(body)
            complexity += complexityVisitor.complexity
        }
        
        // Extract keywords
        var keywords = extractKeywords(from: name)
        keywords.append(contentsOf: parameters.flatMap { extractKeywords(from: $0) })
        keywords = Array(Set(keywords))  // dedupe
        
        let bodyText = node.body?.description ?? ""
        let hasSmells = bodyText.contains("!") && !bodyText.contains("!=")  // Force unwrap, not inequality
        
        // Check if function throws
        let hasThrows = node.signature.effectSpecifiers?.throwsSpecifier != nil
        
        // Detect patterns (using analyzer findings + signature analysis)
        let patterns = detectPatterns(signature: signature, bodyText: bodyText, hasThrows: hasThrows, startLine: startLine, endLine: endLine)
        
        // Module path
        let modulePath = extractModulePath(from: filePath)
        
        let kind: CodeChunk.ChunkKind = currentType != nil ? .method : .function
        
        return CodeChunk(
            id: "\(filePath):\(startLine)",
            file: filePath,
            line: startLine,
            endLine: endLine,
            name: name,
            kind: kind,
            parentType: currentType,
            modulePath: modulePath,
            signature: signature,
            parameters: parameters,
            returnType: returnType,
            docComment: docComment,
            purpose: nil,
            calls: Array(Set(calls)),  // Dedupe calls
            calledBy: [],
            usesTypes: Array(Set(usesTypes)),  // Dedupe types too
            conformsTo: [],
            complexity: complexity,
            lineCount: endLine - startLine + 1,
            visibility: visibility,
            isSingleton: false,
            hasSmells: hasSmells,
            hasTodo: bodyText.contains("TODO") || bodyText.contains("FIXME"),
            keywords: keywords,
            layer: inferLayerForChunk(typeName: currentType),
            imports: imports,
            patterns: patterns
        )
    }
    
    private func makeInitializerChunk(node: InitializerDeclSyntax) -> CodeChunk {
        let name = "init"
        let startLine = lineNumber(for: node.position) ?? 1
        let endLine = lineNumber(for: node.endPosition) ?? startLine
        
        // Extract parameters
        let parameters = node.signature.parameterClause.parameters.map { param in
            param.firstName.text
        }
        
        let signature = "init(\(parameters.joined(separator: ":") + (parameters.isEmpty ? "" : ":")))"
        let visibility = extractVisibility(from: node.modifiers)
        let docComment = extractDocComment(for: node)
        
        let modulePath = extractModulePath(from: filePath)
        
        // Check if init throws
        let hasThrows = node.signature.effectSpecifiers?.throwsSpecifier != nil
        let bodyText = node.body?.description ?? ""
        let patterns = detectPatterns(signature: signature, bodyText: bodyText, hasThrows: hasThrows, startLine: startLine, endLine: endLine)
        
        return CodeChunk(
            id: "\(filePath):\(startLine)",
            file: filePath,
            line: startLine,
            endLine: endLine,
            name: name,
            kind: .initializer,
            parentType: currentType,
            modulePath: modulePath,
            signature: signature,
            parameters: parameters,
            returnType: nil,
            docComment: docComment,
            purpose: nil,
            calls: [],
            calledBy: [],
            usesTypes: [],
            conformsTo: [],
            complexity: 1,
            lineCount: endLine - startLine + 1,
            visibility: visibility,
            isSingleton: false,
            hasSmells: false,
            hasTodo: false,
            keywords: extractKeywords(from: currentType ?? ""),
            layer: inferLayerForChunk(typeName: currentType),
            imports: imports,
            patterns: patterns
        )
    }
    
    private func extractVisibility(from modifiers: DeclModifierListSyntax) -> CodeChunk.Visibility {
        for modifier in modifiers {
            switch modifier.name.text {
            case "public": return .public
            case "private": return .private
            case "fileprivate": return .fileprivate
            case "internal": return .internal
            case "open": return .open
            default: continue
            }
        }
        return .internal
    }
    
    private func extractDocComment(for node: some SyntaxProtocol) -> String? {
        // Look for leading trivia containing doc comments
        let trivia = node.leadingTrivia
        var docLines: [String] = []
        
        for piece in trivia {
            switch piece {
            case .docLineComment(let comment):
                let cleaned = comment
                    .replacingOccurrences(of: "///", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    docLines.append(cleaned)
                }
            case .docBlockComment(let comment):
                let cleaned = comment
                    .replacingOccurrences(of: "/**", with: "")
                    .replacingOccurrences(of: "*/", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    docLines.append(cleaned)
                }
            default:
                continue
            }
        }
        
        return docLines.isEmpty ? nil : docLines.joined(separator: " ")
    }
    
    private func extractKeywords(from name: String) -> [String] {
        // Split camelCase into words
        var keywords: [String] = []
        var currentWord = ""
        
        for char in name {
            if char.isUppercase && !currentWord.isEmpty {
                keywords.append(currentWord.lowercased())
                currentWord = String(char)
            } else {
                currentWord.append(char)
            }
        }
        if !currentWord.isEmpty {
            keywords.append(currentWord.lowercased())
        }
        
        // Expand common abbreviations
        let expansions: [String: String] = [
            "auth": "authentication",
            "btn": "button",
            "vc": "viewcontroller",
            "vm": "viewmodel",
            "mgr": "manager",
            "ctx": "context",
            "req": "request",
            "res": "response",
            "cfg": "config",
            "init": "initialize"
        ]
        
        keywords = keywords.flatMap { word -> [String] in
            if let expansion = expansions[word] {
                return [word, expansion]
            }
            return [word]
        }
        
        return keywords.filter { $0.count > 2 }  // Skip very short words
    }
    
    private func extractModulePath(from filePath: String) -> String {
        // Extract meaningful path components
        let components = filePath.split(separator: "/")
        // Skip common prefixes and file extension
        let meaningful = components.dropFirst(0).dropLast().suffix(3)
        return meaningful.joined(separator: "/")
    }
    
    private func calculateComplexity(_ code: String) -> Int {
        // Simple cyclomatic complexity approximation
        var complexity = 1
        let patterns = ["if ", "else ", "for ", "while ", "case ", "guard ", "catch ", "&&", "||", "?:"]
        for pattern in patterns {
            complexity += code.components(separatedBy: pattern).count - 1
        }
        return complexity
    }
    
    private func lineNumber(for position: AbsolutePosition) -> Int? {
        let offset = position.utf8Offset
        var line = 1
        var currentOffset = 0
        
        for char in sourceText.utf8 {
            if currentOffset >= offset { break }
            if char == UInt8(ascii: "\n") { line += 1 }
            currentOffset += 1
        }
        
        return line
    }
}

// MARK: - Call Extractor Visitor

final class CallExtractorVisitor: SyntaxVisitor {
    private(set) var calls: [String] = []
    private(set) var types: [String] = []
    
    init() {
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespaces)
        
        // Extract the method name
        if let lastDot = callText.lastIndex(of: ".") {
            let methodName = String(callText[callText.index(after: lastDot)...])
            let typePart = String(callText[..<lastDot])
            calls.append(callText)
            if !typePart.isEmpty && typePart.first?.isUppercase == true {
                types.append(typePart)
            }
        } else {
            calls.append(callText)
        }
        
        return .visitChildren
    }
    
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // Track type references
        let base = node.base?.description.trimmingCharacters(in: .whitespaces) ?? ""
        if base.first?.isUppercase == true {
            types.append(base)
        }
        return .visitChildren
    }
}
