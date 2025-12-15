import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Code Chunk Model

public struct CodeChunk: Codable {
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
    
    // Attributes & Property Wrappers (for concurrency/SwiftUI analysis)
    let attributes: [String]        // @MainActor, @available, @discardableResult, @objc, etc.
    let propertyWrappers: [String]  // @State, @Published, @ObservedObject, @Binding, etc.
    
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
        if !attributes.isEmpty {
            parts.append("Attributes: \(attributes.joined(separator: ", "))")
        }
        if !propertyWrappers.isEmpty {
            parts.append("PropertyWrappers: \(propertyWrappers.joined(separator: ", "))")
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
    
    public enum ChunkKind: String, Codable, Sendable {
        case function
        case method
        case initializer
        case property
        case `class`
        case `struct`
        case `enum`
        case `protocol`
        case `extension`
        case hotspot  // File-level health/quality summary
        case fileSummary  // File-level overview (all files)
        case cluster  // Group of related files
        case typeSummary  // Type-level overview across all extensions
    }

    public enum Visibility: String, Codable, Sendable {
        case `public`
        case `internal`
        case `private`
        case `fileprivate`
        case `open`
    }
}

// MARK: - File Findings (from existing analyzers)

public struct FileFindings {
    public var singletonLines: Set<Int> = []
    public var reactiveLines: Set<Int> = []
    public var networkLines: Set<Int> = []
    public var delegateLines: Set<Int> = []
    
    public init() {}
    
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
    private let cache: ASTCache?
    private let verbose: Bool
    
    init(cache: ASTCache? = nil, verbose: Bool = false) {
        self.cache = cache
        self.verbose = verbose
    }
    
    func extractChunks(from parsedFiles: [ParsedFile]) -> [CodeChunk] {
        let startTime = Date()
        
        // Thread-safe collections for parallel processing
        let lock = NSLock()
        var findingsByFile: [String: FileFindings] = [:]
        var allFileChunks: [[CodeChunk]] = Array(repeating: [], count: parsedFiles.count)
        var findingsHits = 0
        var findingsMisses = 0
        var chunkHits = 0
        var chunkMisses = 0
        
        // Step 1: Parallel extraction (findings + chunks per file)
        DispatchQueue.concurrentPerform(iterations: parsedFiles.count) { index in
            let file = parsedFiles[index]
            
            // Check chunk cache first (includes findings implicitly)
            if let cachedChunks = cache?.getChunks(for: file) {
                lock.lock()
                allFileChunks[index] = cachedChunks
                chunkHits += 1
                lock.unlock()
                return
            }
            
            lock.lock()
            chunkMisses += 1
            lock.unlock()
            
            // Get or compute findings
            var findings: FileFindings
            if let cachedFindings = cache?.getFindings(for: file) {
                lock.lock()
                findingsHits += 1
                lock.unlock()
                findings = cachedFindings
            } else {
                lock.lock()
                findingsMisses += 1
                lock.unlock()
                
                findings = FileFindings()
                
                // Run all analyzers
                let singletonVisitor = FileAnalyzer(filePath: file.relativePath, sourceText: file.sourceText)
                singletonVisitor.walk(file.ast)
                findings.singletonLines = Set(singletonVisitor.references.compactMap { $0.line })
                
                let reactiveVisitor = ReactiveVisitor(filePath: file.relativePath, sourceText: file.sourceText)
                reactiveVisitor.walk(file.ast)
                findings.reactiveLines = Set(reactiveVisitor.subscriptions.compactMap { $0.line })
                
                let networkVisitor = NetworkVisitor(filePath: file.relativePath, sourceText: file.sourceText)
                networkVisitor.walk(file.ast)
                findings.networkLines = Set(networkVisitor.endpoints.compactMap { $0.line })
                
                let delegateVisitor = DelegateWiringVisitor(filePath: file.relativePath, sourceText: file.sourceText)
                delegateVisitor.walk(file.ast)
                findings.delegateLines = Set(delegateVisitor.wirings.compactMap { $0.line })
                
                cache?.cacheFindings(findings, for: file)
            }
            
            lock.lock()
            findingsByFile[file.relativePath] = findings
            lock.unlock()
            
            // Extract chunks
            let imports = extractImports(from: file.ast)
            let visitor = ChunkVisitor(
                filePath: file.relativePath,
                sourceText: file.sourceText,
                imports: imports,
                findings: findings
            )
            visitor.walk(file.ast)
            
            // Cache chunks for this file
            cache?.cacheChunks(visitor.chunks, for: file)
            
            lock.lock()
            allFileChunks[index] = visitor.chunks
            lock.unlock()
        }
        
        // Flatten chunks
        var allChunks = allFileChunks.flatMap { $0 }
        
        if verbose {
            let elapsed = Date().timeIntervalSince(startTime)
            fputs("[ChunkExtractor] Extracted \(allChunks.count) chunks in \(String(format: "%.2f", elapsed))s\n", stderr)
            fputs("[ChunkExtractor] Chunk cache: \(chunkHits) hits, \(chunkMisses) misses\n", stderr)
            fputs("[ChunkExtractor] Findings cache: \(findingsHits) hits, \(findingsMisses) misses\n", stderr)
        }
        
        // Step 2: Build call graph (sequential, fast)
        var callGraph: [String: Set<String>] = [:]
        for chunk in allChunks {
            let callerId = "\(chunk.parentType ?? "").\(chunk.name)"
            callGraph[callerId] = Set(chunk.calls)
        }
        
        // Second pass: fill in "calledBy" relationships
        // Normalize call strings to extract just the method name
        func normalizeCall(_ call: String) -> String {
            var s = call
            // Strip leading dot (enum cases like ".loginRequested")
            if s.hasPrefix(".") { s = String(s.dropFirst()) }
            // Extract just the method name from "instance.method" or "Type.method"
            if let dot = s.lastIndex(of: ".") {
                s = String(s[s.index(after: dot)...])
            }
            return s
        }
        
        var calledByMap: [String: [String]] = [:]
        for (caller, callees) in callGraph {
            for callee in callees {
                // Store under normalized key (just the method name)
                let normalizedCallee = normalizeCall(callee)
                calledByMap[normalizedCallee, default: []].append(caller)
            }
        }
        
        // Update chunks with calledBy
        allChunks = allChunks.map { chunk in
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
                calledBy: calledByMap[chunkId] ?? calledByMap[chunk.name] ?? [],
                usesTypes: chunk.usesTypes,
                conformsTo: chunk.conformsTo,
                complexity: chunk.complexity,
                lineCount: chunk.lineCount,
                visibility: chunk.visibility,
                isSingleton: chunk.isSingleton,
                hasSmells: chunk.hasSmells,
                hasTodo: chunk.hasTodo,
                attributes: chunk.attributes,
                propertyWrappers: chunk.propertyWrappers,
                keywords: chunk.keywords,
                layer: chunk.layer,
                imports: chunk.imports,
                patterns: chunk.patterns
            )
        }
        
        // Step 3: Generate hotspot chunks (file-level health summaries)
        let hotspotChunks = generateHotspotChunks(from: allChunks, parsedFiles: parsedFiles)
        allChunks.append(contentsOf: hotspotChunks)
        
        // Step 4: Generate file summary chunks (one per file)
        let fileSummaryChunks = generateFileSummaryChunks(from: allChunks, parsedFiles: parsedFiles)
        allChunks.append(contentsOf: fileSummaryChunks)
        
        // Create TypeMap once for cluster and type summary generation
        let graphAnalyzer = DependencyGraphAnalyzer()
        let typeMap = graphAnalyzer.analyzeTypes(parsedFiles: parsedFiles)
        
        // Step 5: Generate cluster chunks (groups of related files)
        let clusterChunks = generateClusterChunks(from: allChunks, parsedFiles: parsedFiles, typeMap: typeMap)
        allChunks.append(contentsOf: clusterChunks)
        
        // Step 6: Generate type summary chunks (aggregate across extensions)
        let typeSummaryChunks = generateTypeSummaryChunks(from: allChunks, typeMap: typeMap)
        allChunks.append(contentsOf: typeSummaryChunks)
        
        if verbose {
            fputs("[ChunkExtractor] Added \(hotspotChunks.count) hotspot, \(fileSummaryChunks.count) summary, \(clusterChunks.count) cluster, \(typeSummaryChunks.count) typeSummary chunks\n", stderr)
        }

        return allChunks
    }

    /// Generate only virtual chunks (hotspots, summaries, clusters, typeSummaries)
    /// Used for incremental updates when file chunks already exist
    /// - Parameters:
    ///   - fileChunks: All file-level chunks (non-virtual)
    ///   - parsedFiles: All parsed files in the project (needed for analyzers)
    /// - Returns: Array of virtual chunks only
    func generateVirtualChunks(from fileChunks: [CodeChunk], parsedFiles: [ParsedFile]) -> [CodeChunk] {
        guard !parsedFiles.isEmpty else { return [] }

        let startTime = Date()

        // Build call graph for calledBy relationships (same as extractChunks)
        var callGraph: [String: Set<String>] = [:]
        for chunk in fileChunks {
            let callerId = "\(chunk.parentType ?? "").\(chunk.name)"
            callGraph[callerId] = Set(chunk.calls)
        }

        // Generate virtual chunks
        let hotspotChunks = generateHotspotChunks(from: fileChunks, parsedFiles: parsedFiles)
        let fileSummaryChunks = generateFileSummaryChunks(from: fileChunks, parsedFiles: parsedFiles)

        let graphAnalyzer = DependencyGraphAnalyzer()
        let typeMap = graphAnalyzer.analyzeTypes(parsedFiles: parsedFiles)

        let clusterChunks = generateClusterChunks(from: fileChunks, parsedFiles: parsedFiles, typeMap: typeMap)
        let typeSummaryChunks = generateTypeSummaryChunks(from: fileChunks, typeMap: typeMap)

        var virtualChunks: [CodeChunk] = []
        virtualChunks.append(contentsOf: hotspotChunks)
        virtualChunks.append(contentsOf: fileSummaryChunks)
        virtualChunks.append(contentsOf: clusterChunks)
        virtualChunks.append(contentsOf: typeSummaryChunks)

        if verbose {
            let elapsed = Date().timeIntervalSince(startTime)
            fputs("[ChunkExtractor] Generated \(virtualChunks.count) virtual chunks (\(hotspotChunks.count) hotspot, \(fileSummaryChunks.count) summary, \(clusterChunks.count) cluster, \(typeSummaryChunks.count) typeSummary) in \(String(format: "%.2f", elapsed))s\n", stderr)
        }

        return virtualChunks
    }

    /// Extract only file-level chunks (no virtual chunks) for a set of files
    /// Used for incremental updates
    func extractFileChunks(from parsedFiles: [ParsedFile]) -> [CodeChunk] {
        guard !parsedFiles.isEmpty else { return [] }

        let lock = NSLock()
        var allFileChunks: [[CodeChunk]] = Array(repeating: [], count: parsedFiles.count)

        // Parallel extraction (same as extractChunks but without virtual chunk generation)
        DispatchQueue.concurrentPerform(iterations: parsedFiles.count) { index in
            let file = parsedFiles[index]

            // Check chunk cache first
            if let cachedChunks = cache?.getChunks(for: file) {
                // Filter out any virtual chunks from cache
                let fileOnly = cachedChunks.filter { !Self.virtualChunkKinds.contains($0.kind) }
                lock.lock()
                allFileChunks[index] = fileOnly
                lock.unlock()
                return
            }

            // Get or compute findings
            var findings = cache?.getFindings(for: file) ?? FileFindings()
            if cache?.getFindings(for: file) == nil {
                findings = FileFindings()

                let singletonVisitor = FileAnalyzer(filePath: file.relativePath, sourceText: file.sourceText)
                singletonVisitor.walk(file.ast)
                findings.singletonLines = Set(singletonVisitor.references.compactMap { $0.line })

                let reactiveVisitor = ReactiveVisitor(filePath: file.relativePath, sourceText: file.sourceText)
                reactiveVisitor.walk(file.ast)
                findings.reactiveLines = Set(reactiveVisitor.subscriptions.compactMap { $0.line })

                let networkVisitor = NetworkVisitor(filePath: file.relativePath, sourceText: file.sourceText)
                networkVisitor.walk(file.ast)
                findings.networkLines = Set(networkVisitor.endpoints.compactMap { $0.line })

                let delegateVisitor = DelegateWiringVisitor(filePath: file.relativePath, sourceText: file.sourceText)
                delegateVisitor.walk(file.ast)
                findings.delegateLines = Set(delegateVisitor.wirings.compactMap { $0.line })

                cache?.cacheFindings(findings, for: file)
            }

            // Extract chunks
            let chunks = extractFileChunksFromAST(file: file, findings: findings)

            lock.lock()
            allFileChunks[index] = chunks
            cache?.cacheChunks(chunks, for: file)
            lock.unlock()
        }

        return allFileChunks.flatMap { $0 }
    }

    /// Virtual chunk kinds
    private static let virtualChunkKinds: Set<CodeChunk.ChunkKind> = [.hotspot, .fileSummary, .cluster, .typeSummary]

    /// Extract file-level chunks from a single file's AST
    private func extractFileChunksFromAST(file: ParsedFile, findings: FileFindings) -> [CodeChunk] {
        let imports = extractImports(from: file.ast)
        let visitor = ChunkVisitor(
            filePath: file.relativePath,
            sourceText: file.sourceText,
            imports: imports,
            findings: findings
        )
        visitor.walk(file.ast)
        return visitor.chunks
    }

    /// Generate hotspot chunks for files with quality issues
    /// Uses actual analyzers for accurate data
    private func generateHotspotChunks(from chunks: [CodeChunk], parsedFiles: [ParsedFile]) -> [CodeChunk] {
        var hotspots: [CodeChunk] = []
        
        // Run actual analyzers for accurate data
        let smellAnalyzer = CodeSmellAnalyzer()
        let smellReport = smellAnalyzer.analyze(parsedFiles: parsedFiles)
        
        let metricsAnalyzer = FunctionMetricsAnalyzer()
        let metricsReport = metricsAnalyzer.analyze(parsedFiles: parsedFiles)
        
        // Group data by file
        var chunksByFile: [String: [CodeChunk]] = [:]
        for chunk in chunks {
            chunksByFile[chunk.file, default: []].append(chunk)
        }
        
        // Group god functions by file
        var godFunctionsByFile: [String: [FunctionMetric]] = [:]
        for gf in metricsReport.godFunctions {
            godFunctionsByFile[gf.file, default: []].append(gf)
        }
        
        // Group smells by file and type
        var smellDetailsByFile: [String: [String: Int]] = [:]  // file -> (type -> count)
        for smell in smellReport.smells {
            smellDetailsByFile[smell.file, default: [:]][smell.type.rawValue, default: 0] += 1
        }
        
        for file in parsedFiles {
            let fileChunks = chunksByFile[file.relativePath] ?? []
            let fileGodFunctions = godFunctionsByFile[file.relativePath] ?? []
            let fileSmellDetails = smellDetailsByFile[file.relativePath] ?? [:]
            let totalSmells = smellReport.smellsByFile[file.relativePath] ?? 0
            
            // Count from chunks (these are accurate)
            let todoCount = fileChunks.filter { $0.hasTodo }.count
            let singletonCount = fileChunks.filter { $0.isSingleton }.count
            let totalComplexity = fileChunks.compactMap { $0.complexity }.reduce(0, +)
            let totalLines = file.sourceText.components(separatedBy: .newlines).count
            
            // Only create hotspot if file has significant issues
            let hasIssues = fileGodFunctions.count > 0 || totalSmells >= 5 || singletonCount > 0
            guard hasIssues else { continue }
            
            // Build detailed hotspot description
            var issues: [String] = []
            
            if fileGodFunctions.count > 0 {
                let names = fileGodFunctions.prefix(3).map { $0.name }.joined(separator: ", ")
                issues.append("\(fileGodFunctions.count) god functions: \(names)")
            }
            
            if totalSmells > 0 {
                // Include breakdown by type
                let breakdown = fileSmellDetails
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { "\($0.value) \($0.key)" }
                    .joined(separator: ", ")
                issues.append("\(totalSmells) smells (\(breakdown))")
            }
            
            if singletonCount > 0 {
                issues.append("\(singletonCount) singletons")
            }
            
            if todoCount > 0 {
                issues.append("\(todoCount) TODOs")
            }
            
            // Collect unique attributes and patterns from file
            let allAttributes = Set(fileChunks.flatMap { $0.attributes })
            let allPatterns = Set(fileChunks.flatMap { $0.patterns })
            
            // Derive modulePath and imports from existing chunks
            let modulePath = fileChunks.first?.modulePath ?? ""
            let fileImports = fileChunks.first?.imports ?? []
            
            let hotspot = CodeChunk(
                id: "hotspot:\(file.relativePath)",
                file: file.relativePath,
                line: 1,
                endLine: totalLines,
                name: (file.relativePath as NSString).lastPathComponent,
                kind: .hotspot,
                parentType: nil,
                modulePath: modulePath,
                signature: "Hotspot: \(file.relativePath)",
                parameters: [],
                returnType: nil,
                docComment: nil,
                purpose: "File health: \(issues.joined(separator: ", "))",
                calls: [],
                calledBy: [],
                usesTypes: [],
                conformsTo: [],
                complexity: totalComplexity,
                lineCount: totalLines,
                visibility: .internal,
                isSingleton: singletonCount > 0,
                hasSmells: totalSmells > 0,
                hasTodo: todoCount > 0,
                attributes: Array(allAttributes),
                propertyWrappers: [],
                keywords: ["hotspot", "refactor", "quality", "tech-debt"],
                layer: fileChunks.first?.layer ?? "unknown",
                imports: fileImports,
                patterns: Array(allPatterns)
            )
            hotspots.append(hotspot)
        }
        
        return hotspots
    }
    
    /// Generate file summary chunks for all files
    private func generateFileSummaryChunks(from chunks: [CodeChunk], parsedFiles: [ParsedFile]) -> [CodeChunk] {
        var summaries: [CodeChunk] = []
        
        // Group chunks by file
        var chunksByFile: [String: [CodeChunk]] = [:]
        for chunk in chunks where chunk.kind != .hotspot {
            chunksByFile[chunk.file, default: []].append(chunk)
        }
        
        for file in parsedFiles {
            let fileChunks = chunksByFile[file.relativePath] ?? []
            guard !fileChunks.isEmpty else { continue }
            
            // Aggregate metadata
            let types = fileChunks.filter { [.class, .struct, .enum, .protocol].contains($0.kind) }
            let methods = fileChunks.filter { $0.kind == .method || $0.kind == .function }
            let publicAPIs = methods.filter { $0.visibility == .public || $0.visibility == .open }
            let protocols = Set(fileChunks.flatMap { $0.conformsTo })
            let allAttributes = Set(fileChunks.flatMap { $0.attributes })
            let allPatterns = Set(fileChunks.flatMap { $0.patterns })
            let totalLines = file.sourceText.components(separatedBy: .newlines).count
            
            // Build summary description
            var parts: [String] = []
            
            // Types
            if !types.isEmpty {
                let typeNames = types.prefix(3).map { $0.name }
                let typeDesc = types.count > 3 ? "\(typeNames.joined(separator: ", "))..." : typeNames.joined(separator: ", ")
                parts.append("\(types.count) types: \(typeDesc)")
            }
            
            // Methods
            if !methods.isEmpty {
                parts.append("\(methods.count) methods")
            }
            
            // Public API
            if !publicAPIs.isEmpty {
                parts.append("\(publicAPIs.count) public")
            }
            
            // Protocols
            if !protocols.isEmpty {
                let protoList = protocols.prefix(3).joined(separator: ", ")
                parts.append("conforms to \(protoList)")
            }
            
            // Key attributes
            if allAttributes.contains("@MainActor") {
                parts.append("@MainActor")
            }
            if allAttributes.contains("@Observable") || allPatterns.contains("reactive") {
                parts.append("reactive")
            }
            
            let modulePath = fileChunks.first?.modulePath ?? ""
            let fileImports = fileChunks.first?.imports ?? []
            let layer = fileChunks.first?.layer ?? "unknown"
            
            let summary = CodeChunk(
                id: "summary:\(file.relativePath)",
                file: file.relativePath,
                line: 1,
                endLine: totalLines,
                name: (file.relativePath as NSString).lastPathComponent,
                kind: .fileSummary,
                parentType: nil,
                modulePath: modulePath,
                signature: file.relativePath,
                parameters: [],
                returnType: nil,
                docComment: nil,
                purpose: parts.joined(separator: ", "),
                calls: [],
                calledBy: [],
                usesTypes: Array(Set(fileChunks.flatMap { $0.usesTypes })),
                conformsTo: Array(protocols),
                complexity: nil,
                lineCount: totalLines,
                visibility: .internal,
                isSingleton: fileChunks.contains { $0.isSingleton },
                hasSmells: fileChunks.contains { $0.hasSmells },
                hasTodo: fileChunks.contains { $0.hasTodo },
                attributes: Array(allAttributes),
                propertyWrappers: [],
                keywords: ["file", "summary", layer],
                layer: layer,
                imports: fileImports,
                patterns: Array(allPatterns)
            )
            summaries.append(summary)
        }
        
        return summaries
    }
    
    /// Generate cluster chunks using DependencyGraphAnalyzer for smarter grouping
    private func generateClusterChunks(from chunks: [CodeChunk], parsedFiles: [ParsedFile], typeMap: TypeMap) -> [CodeChunk] {
        var clusters: [CodeChunk] = []
        
        // Standard library imports to ignore for clustering
        let standardImports: Set<String> = ["Foundation", "UIKit", "SwiftUI", "Combine", "Swift"]
        
        // 1. Cluster by protocol conformance (files implementing same protocol are related)
        for (proto, conformers) in typeMap.protocolConformances where conformers.count >= 2 {
            // Map conforming types to their files
            var filesForProtocol: Set<String> = []
            for conformer in conformers {
                if let file = typeMap.typeToFile[conformer] {
                    filesForProtocol.insert(file)
                }
            }
            
            guard filesForProtocol.count >= 2 else { continue }
            
            let fileList = filesForProtocol.sorted()
            let summaryChunks = chunks.filter { $0.kind == .fileSummary && filesForProtocol.contains($0.file) }
            let allImports = Set(summaryChunks.flatMap { $0.imports }).subtracting(standardImports)
            let allPatterns = Set(summaryChunks.flatMap { $0.patterns })
            let allAttributes = Set(summaryChunks.flatMap { $0.attributes })
            let primaryLayer = summaryChunks.first?.layer ?? "unknown"
            
            let fileNames = fileList.prefix(5).map { ($0 as NSString).lastPathComponent }
            let fileDesc = fileList.count > 5 ? "\(fileNames.joined(separator: ", "))... (\(fileList.count) files)" : fileNames.joined(separator: ", ")
            
            let cluster = CodeChunk(
                id: "cluster:protocol:\(proto)",
                file: "protocol:\(proto)",
                line: 1,
                endLine: 1,
                name: "\(proto) conformers",
                kind: .cluster,
                parentType: nil,
                modulePath: proto,
                signature: "Cluster: \(proto) protocol conformers",
                parameters: [],
                returnType: nil,
                docComment: nil,
                purpose: "\(fileList.count) files conform to \(proto): \(fileDesc). Imports: \(allImports.prefix(3).joined(separator: ", "))",
                calls: [],
                calledBy: [],
                usesTypes: [],
                conformsTo: [proto],
                complexity: nil,
                lineCount: fileList.count,
                visibility: .internal,
                isSingleton: false,
                hasSmells: false,
                hasTodo: false,
                attributes: Array(allAttributes),
                propertyWrappers: [],
                keywords: ["cluster", "protocol", proto.lowercased(), primaryLayer],
                layer: primaryLayer,
                imports: Array(allImports),
                patterns: Array(allPatterns)
            )
            clusters.append(cluster)
        }
        
        // 2. Keep directory clusters as secondary grouping
        var filesByModule: [String: Set<String>] = [:]
        for chunk in chunks where chunk.kind == .fileSummary {
            let module = chunk.modulePath.isEmpty ? "Root" : chunk.modulePath
            filesByModule[module, default: []].insert(chunk.file)
        }
        
        for (module, files) in filesByModule where files.count >= 2 {
            let fileList = files.sorted()
            let summaryChunks = chunks.filter { $0.kind == .fileSummary && files.contains($0.file) }
            let allImports = Set(summaryChunks.flatMap { $0.imports }).subtracting(standardImports)
            let allPatterns = Set(summaryChunks.flatMap { $0.patterns })
            let allAttributes = Set(summaryChunks.flatMap { $0.attributes })
            let primaryLayer = summaryChunks.first?.layer ?? "unknown"
            
            let fileNames = fileList.prefix(5).map { ($0 as NSString).lastPathComponent }
            let fileDesc = fileList.count > 5 ? "\(fileNames.joined(separator: ", "))... (\(fileList.count) files)" : fileNames.joined(separator: ", ")
            
            let sharedImports = allImports.filter { imp in
                let count = summaryChunks.filter { $0.imports.contains(imp) }.count
                return count >= max(1, summaryChunks.count / 2)
            }
            
            let cluster = CodeChunk(
                id: "cluster:dir:\(module)",
                file: module,
                line: 1,
                endLine: 1,
                name: (module as NSString).lastPathComponent,
                kind: .cluster,
                parentType: nil,
                modulePath: module,
                signature: "Cluster: \(module)",
                parameters: [],
                returnType: nil,
                docComment: nil,
                purpose: "\(fileList.count) files: \(fileDesc). Shared: \(sharedImports.prefix(5).joined(separator: ", "))",
                calls: [],
                calledBy: [],
                usesTypes: [],
                conformsTo: [],
                complexity: nil,
                lineCount: fileList.count,
                visibility: .internal,
                isSingleton: false,
                hasSmells: false,
                hasTodo: false,
                attributes: Array(allAttributes),
                propertyWrappers: [],
                keywords: ["cluster", "module", primaryLayer],
                layer: primaryLayer,
                imports: Array(sharedImports),
                patterns: Array(allPatterns)
            )
            clusters.append(cluster)
        }
        
        return clusters
    }
    
    /// Generate type summary chunks aggregating across all extensions
    private func generateTypeSummaryChunks(from chunks: [CodeChunk], typeMap: TypeMap) -> [CodeChunk] {
        var summaries: [CodeChunk] = []
        
        // Group definitions by type name (includes base type + extensions)
        var typeFiles: [String: Set<String>] = [:]
        var typeConformances: [String: Set<String>] = [:]
        var typeKinds: [String: TypeDefinition.TypeKind] = [:]
        
        for def in typeMap.definitions {
            typeFiles[def.name, default: []].insert(def.file)
            typeConformances[def.name, default: []].formUnion(def.conformances)
            // Store the kind of the base type (not extension)
            if def.kind != .extension {
                typeKinds[def.name] = def.kind
            }
        }
        
        // Count methods per type from chunks
        var typeMethods: [String: (total: Int, publicCount: Int, keyMethods: [String])] = [:]
        for chunk in chunks where chunk.kind == .method || chunk.kind == .function || chunk.kind == .initializer {
            guard let parent = chunk.parentType else { continue }
            var current = typeMethods[parent] ?? (total: 0, publicCount: 0, keyMethods: [])
            current.total += 1
            if chunk.visibility == .public || chunk.visibility == .open {
                current.publicCount += 1
                if current.keyMethods.count < 5 {
                    current.keyMethods.append(chunk.name)
                }
            }
            typeMethods[parent] = current
        }
        
        // Get imports and attributes per type
        var typeImports: [String: Set<String>] = [:]
        var typeAttributes: [String: Set<String>] = [:]
        for chunk in chunks {
            guard let parent = chunk.parentType else { continue }
            typeImports[parent, default: []].formUnion(chunk.imports)
            typeAttributes[parent, default: []].formUnion(chunk.attributes)
        }
        
        // Create TypeSummary chunk for each unique type (skip protocols for now)
        for (typeName, files) in typeFiles {
            let kind = typeKinds[typeName]
            // Skip protocols - they don't have implementations to aggregate
            guard kind != .protocol else { continue }
            
            let uniqueFiles = Array(files).sorted()
            let conformances = Array(typeConformances[typeName] ?? []).sorted()
            let methods = typeMethods[typeName] ?? (total: 0, publicCount: 0, keyMethods: [])
            let imports = Array(typeImports[typeName] ?? []).sorted()
            let attributes = Array(typeAttributes[typeName] ?? []).sorted()
            
            // Build purpose string
            var purposeParts: [String] = []
            if uniqueFiles.count > 1 {
                let fileNames = uniqueFiles.map { ($0 as NSString).lastPathComponent }
                purposeParts.append("\(uniqueFiles.count) files: \(fileNames.joined(separator: ", "))")
            }
            purposeParts.append("\(methods.total) methods (\(methods.publicCount) public)")
            if !conformances.isEmpty {
                purposeParts.append("Conforms to: \(conformances.prefix(5).joined(separator: ", "))")
            }
            if !methods.keyMethods.isEmpty {
                purposeParts.append("Key: \(methods.keyMethods.joined(separator: ", "))")
            }
            
            // Determine layer from first file chunk
            let typeChunks = chunks.filter { $0.parentType == typeName }
            let layer = typeChunks.first?.layer ?? "unknown"
            
            let summary = CodeChunk(
                id: "typeSummary:\(typeName)",
                file: typeMap.typeToFile[typeName] ?? uniqueFiles.first ?? "unknown",
                line: 1,
                endLine: 1,
                name: typeName,
                kind: .typeSummary,
                parentType: nil,
                modulePath: typeName,
                signature: "TypeSummary: \(typeName)",
                parameters: [],
                returnType: nil,
                docComment: nil,
                purpose: purposeParts.joined(separator: ". "),
                calls: [],
                calledBy: [],
                usesTypes: [],
                conformsTo: conformances,
                complexity: nil,
                lineCount: methods.total,
                visibility: .public,
                isSingleton: false,
                hasSmells: false,
                hasTodo: false,
                attributes: attributes,
                propertyWrappers: [],
                keywords: ["type", "summary", typeName.lowercased()],
                layer: layer,
                imports: imports,
                patterns: []
            )
            summaries.append(summary)
        }
        
        return summaries
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
        
        // Extract attributes and property wrappers
        let attributes = extractAttributes(from: node)
        let propertyWrappers = extractPropertyWrappers(from: node)
        
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
            attributes: attributes,
            propertyWrappers: propertyWrappers,
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
        let returnSuffix = returnType.map { " -> \($0)" } ?? ""
        let signature = "func \(name)(\(parameters.joined(separator: ":") + (parameters.isEmpty ? "" : ":")))" + returnSuffix
        
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
        
        // Extract attributes and property wrappers
        let attributes = extractAttributes(from: node)
        let propertyWrappers = extractPropertyWrappers(from: node)
        
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
            attributes: attributes,
            propertyWrappers: propertyWrappers,
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
        
        // Extract attributes and property wrappers
        let attributes = extractAttributes(from: node)
        let propertyWrappers = extractPropertyWrappers(from: node)
        
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
            attributes: attributes,
            propertyWrappers: propertyWrappers,
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
    
    /// Extract attributes like @MainActor, @available, @discardableResult, @objc, etc.
    private func extractAttributes(from node: some SyntaxProtocol) -> [String] {
        var attributes: [String] = []
        
        // Check for AttributeListSyntax in the node's description
        // This is a simplified approach - we look for @Name patterns
        let nodeText = node.description
        
        // Known Swift attributes (not property wrappers)
        let knownAttributes = [
            "@MainActor", "@globalActor", "@Sendable", "@nonisolated",  // Concurrency
            "@available", "@unavailable",                                // Availability
            "@discardableResult", "@inlinable", "@usableFromInline",    // Optimization
            "@objc", "@objcMembers", "@nonobjc",                        // ObjC interop
            "@escaping", "@autoclosure", "@convention",                  // Closures
            "@frozen", "@unknown",                                       // Enums
            "@IBAction", "@IBOutlet", "@IBDesignable", "@IBInspectable", // Interface Builder
            "@testable", "@_exported",                                   // Imports
            "@dynamicMemberLookup", "@dynamicCallable",                 // Dynamic features
            "@propertyWrapper", "@resultBuilder",                        // Meta
            "@preconcurrency", "@unchecked"                             // Safety
        ]
        
        for attr in knownAttributes {
            if nodeText.contains(attr) {
                attributes.append(attr)
            }
        }
        
        return attributes
    }
    
    /// Extract property wrappers like @State, @Published, @ObservedObject, etc.
    private func extractPropertyWrappers(from node: some SyntaxProtocol) -> [String] {
        var wrappers: [String] = []
        
        let nodeText = node.description
        
        // SwiftUI property wrappers
        let swiftUIWrappers = [
            "@State", "@Binding", "@ObservedObject", "@StateObject",
            "@EnvironmentObject", "@Environment", "@Published",
            "@FocusState", "@GestureState", "@SceneStorage",
            "@AppStorage", "@FetchRequest", "@Query"
        ]
        
        // Combine property wrappers
        let combineWrappers = ["@Published"]
        
        // Common third-party wrappers
        let otherWrappers = [
            "@Inject", "@Dependency", "@Default", "@UserDefault",
            "@Persisted", "@Realm"  // Realm
        ]
        
        let allWrappers = swiftUIWrappers + combineWrappers + otherWrappers
        
        for wrapper in allWrappers {
            if nodeText.contains(wrapper) {
                wrappers.append(wrapper)
            }
        }
        
        return Array(Set(wrappers))  // Dedupe
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
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract the method name
        if let lastDot = callText.lastIndex(of: ".") {
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
        let base = node.base?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.first?.isUppercase == true {
            types.append(base)
        }
        return .visitChildren
    }
}
