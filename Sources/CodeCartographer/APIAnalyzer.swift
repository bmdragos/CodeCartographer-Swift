import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - API Surface Analysis

struct APIReport: Codable {
    let analyzedAt: String
    var types: [TypeAPI]
    var globalFunctions: [FunctionSignature]
    var totalPublicAPIs: Int
    var recommendations: [String]
}

struct TypeAPI: Codable {
    let name: String
    let kind: String  // class, struct, enum, protocol
    let file: String
    let line: Int?
    let visibility: String
    var properties: [PropertySignature]
    var methods: [FunctionSignature]
    var conformances: [String]
    var superclass: String?
}

struct PropertySignature: Codable {
    let name: String
    let type: String
    let visibility: String
    let isStatic: Bool
    let isMutable: Bool  // var vs let
    let isComputed: Bool
    let line: Int?
}

struct FunctionSignature: Codable {
    let name: String
    let parameters: [ParameterSignature]
    let returnType: String?
    let visibility: String
    let isStatic: Bool
    let isAsync: Bool
    let doesThrow: Bool
    let line: Int?
    let file: String?  // For global functions
}

struct ParameterSignature: Codable {
    let label: String?  // external name
    let name: String    // internal name
    let type: String
    let hasDefault: Bool
}

// MARK: - API Visitor

final class APIVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var types: [TypeAPI] = []
    private(set) var globalFunctions: [FunctionSignature] = []
    
    private var currentType: TypeAPI?
    private var currentProperties: [PropertySignature] = []
    private var currentMethods: [FunctionSignature] = []
    private var nestingLevel = 0
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // MARK: - Class
    
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        
        // Save current context if nested
        if nestingLevel > 0 {
            return .visitChildren
        }
        
        nestingLevel += 1
        currentProperties = []
        currentMethods = []
        
        var conformances: [String] = []
        var superclass: String? = nil
        
        if let inheritance = node.inheritanceClause {
            for (index, inherited) in inheritance.inheritedTypes.enumerated() {
                let typeName = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if index == 0 && !isProtocol(typeName) {
                    superclass = typeName
                } else {
                    conformances.append(typeName)
                }
            }
        }
        
        currentType = TypeAPI(
            name: node.name.text,
            kind: "class",
            file: filePath,
            line: lineNumber(for: node.position),
            visibility: visibility,
            properties: [],
            methods: [],
            conformances: conformances,
            superclass: superclass
        )
        
        return .visitChildren
    }
    
    override func visitPost(_ node: ClassDeclSyntax) {
        if nestingLevel == 1, var type = currentType {
            type.properties = currentProperties
            type.methods = currentMethods
            types.append(type)
            currentType = nil
        }
        nestingLevel = max(0, nestingLevel - 1)
    }
    
    // MARK: - Struct
    
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        
        if nestingLevel > 0 {
            return .visitChildren
        }
        
        nestingLevel += 1
        currentProperties = []
        currentMethods = []
        
        var conformances: [String] = []
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                conformances.append(inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        
        currentType = TypeAPI(
            name: node.name.text,
            kind: "struct",
            file: filePath,
            line: lineNumber(for: node.position),
            visibility: visibility,
            properties: [],
            methods: [],
            conformances: conformances,
            superclass: nil
        )
        
        return .visitChildren
    }
    
    override func visitPost(_ node: StructDeclSyntax) {
        if nestingLevel == 1, var type = currentType {
            type.properties = currentProperties
            type.methods = currentMethods
            types.append(type)
            currentType = nil
        }
        nestingLevel = max(0, nestingLevel - 1)
    }
    
    // MARK: - Enum
    
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        
        if nestingLevel > 0 {
            return .visitChildren
        }
        
        nestingLevel += 1
        currentProperties = []
        currentMethods = []
        
        var conformances: [String] = []
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                conformances.append(inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        
        currentType = TypeAPI(
            name: node.name.text,
            kind: "enum",
            file: filePath,
            line: lineNumber(for: node.position),
            visibility: visibility,
            properties: [],
            methods: [],
            conformances: conformances,
            superclass: nil
        )
        
        return .visitChildren
    }
    
    override func visitPost(_ node: EnumDeclSyntax) {
        if nestingLevel == 1, var type = currentType {
            type.properties = currentProperties
            type.methods = currentMethods
            types.append(type)
            currentType = nil
        }
        nestingLevel = max(0, nestingLevel - 1)
    }
    
    // MARK: - Protocol
    
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        
        nestingLevel += 1
        currentProperties = []
        currentMethods = []
        
        var conformances: [String] = []
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                conformances.append(inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        
        currentType = TypeAPI(
            name: node.name.text,
            kind: "protocol",
            file: filePath,
            line: lineNumber(for: node.position),
            visibility: visibility,
            properties: [],
            methods: [],
            conformances: conformances,
            superclass: nil
        )
        
        return .visitChildren
    }
    
    override func visitPost(_ node: ProtocolDeclSyntax) {
        if var type = currentType {
            type.properties = currentProperties
            type.methods = currentMethods
            types.append(type)
            currentType = nil
        }
        nestingLevel = max(0, nestingLevel - 1)
    }
    
    // MARK: - Properties
    
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        let isMutable = node.bindingSpecifier.text == "var"
        
        for binding in node.bindings {
            let name = binding.pattern.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = binding.typeAnnotation?.type.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
            let isComputed = binding.accessorBlock != nil
            
            let prop = PropertySignature(
                name: name,
                type: type,
                visibility: visibility,
                isStatic: isStatic,
                isMutable: isMutable,
                isComputed: isComputed,
                line: lineNumber(for: node.position)
            )
            
            if currentType != nil {
                currentProperties.append(prop)
            }
        }
        
        return .skipChildren
    }
    
    // MARK: - Functions
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        let isAsync = node.signature.effectSpecifiers?.asyncSpecifier != nil
        let doesThrow = node.signature.effectSpecifiers?.throwsSpecifier != nil
        
        // Parse parameters
        var parameters: [ParameterSignature] = []
        for param in node.signature.parameterClause.parameters {
            let label = param.firstName.text == "_" ? nil : param.firstName.text
            let name = param.secondName?.text ?? param.firstName.text
            let type = param.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasDefault = param.defaultValue != nil
            
            parameters.append(ParameterSignature(
                label: label,
                name: name,
                type: type,
                hasDefault: hasDefault
            ))
        }
        
        // Return type
        let returnType = node.signature.returnClause?.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let sig = FunctionSignature(
            name: node.name.text,
            parameters: parameters,
            returnType: returnType,
            visibility: visibility,
            isStatic: isStatic,
            isAsync: isAsync,
            doesThrow: doesThrow,
            line: lineNumber(for: node.position),
            file: currentType == nil ? filePath : nil
        )
        
        if currentType != nil {
            currentMethods.append(sig)
        } else if nestingLevel == 0 {
            globalFunctions.append(sig)
        }
        
        return .skipChildren
    }
    
    // MARK: - Helpers
    
    private func getVisibility(from modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            let name = modifier.name.text
            if ["public", "open", "private", "fileprivate", "internal"].contains(name) {
                return name
            }
        }
        return "internal"
    }
    
    private func isProtocol(_ name: String) -> Bool {
        // Common protocol patterns
        let protocolPatterns = ["Protocol", "Delegate", "DataSource", "Codable", "Hashable", "Equatable", "Comparable", "Identifiable", "ObservableObject", "View"]
        return protocolPatterns.contains(where: { name.contains($0) || name.hasSuffix("able") || name.hasSuffix("ing") })
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

// MARK: - API Analyzer

class APIAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> APIReport {
        var allTypes: [TypeAPI] = []
        var allGlobalFunctions: [FunctionSignature] = []
        
        for file in parsedFiles {
            let visitor = APIVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            allTypes.append(contentsOf: visitor.types)
            allGlobalFunctions.append(contentsOf: visitor.globalFunctions)
        }
        
        // Sort by name for easier reading
        allTypes.sort { $0.name < $1.name }
        allGlobalFunctions.sort { $0.name < $1.name }
        
        // Count public APIs
        let publicTypes = allTypes.filter { ["public", "open"].contains($0.visibility) }
        let publicFunctions = allGlobalFunctions.filter { ["public", "open"].contains($0.visibility) }
        let totalPublic = publicTypes.count + publicFunctions.count +
                          publicTypes.flatMap { $0.methods }.filter { ["public", "open"].contains($0.visibility) }.count +
                          publicTypes.flatMap { $0.properties }.filter { ["public", "open"].contains($0.visibility) }.count
        
        // Recommendations
        var recommendations: [String] = []
        
        // Find types with many methods (potential god objects)
        let largeTypes = allTypes.filter { $0.methods.count > 15 }
        if !largeTypes.isEmpty {
            recommendations.append("Large types (>15 methods): \(largeTypes.map { "\($0.name)(\($0.methods.count))" }.joined(separator: ", "))")
        }
        
        // Find analyzers and their analyze methods for refactoring context
        let analyzers = allTypes.filter { $0.name.hasSuffix("Analyzer") }
        if !analyzers.isEmpty {
            recommendations.append("Found \(analyzers.count) Analyzer types - see their analyze() methods for API")
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return APIReport(
            analyzedAt: dateFormatter.string(from: Date()),
            types: allTypes,
            globalFunctions: allGlobalFunctions,
            totalPublicAPIs: totalPublic,
            recommendations: recommendations
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> APIReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
    
    /// Get a concise summary suitable for refactoring context
    func summarizeForRefactoring(report: APIReport, typeNames: [String]? = nil) -> String {
        var output = "# API Summary\n\n"
        
        let typesToShow = typeNames.map { names in
            report.types.filter { names.contains($0.name) }
        } ?? report.types.filter { $0.name.hasSuffix("Analyzer") || $0.name.hasSuffix("Report") }
        
        for type in typesToShow {
            output += "## \(type.kind) \(type.name)\n"
            output += "File: \(type.file)\n"
            
            if !type.properties.isEmpty {
                output += "\nProperties:\n"
                for prop in type.properties {
                    let mutability = prop.isMutable ? "var" : "let"
                    output += "  \(mutability) \(prop.name): \(prop.type)\n"
                }
            }
            
            if !type.methods.isEmpty {
                output += "\nMethods:\n"
                for method in type.methods {
                    let params = method.parameters.map { p in
                        let label = p.label.map { "\($0) " } ?? ""
                        return "\(label)\(p.name): \(p.type)"
                    }.joined(separator: ", ")
                    let returnPart = method.returnType.map { " -> \($0)" } ?? ""
                    output += "  func \(method.name)(\(params))\(returnPart)\n"
                }
            }
            
            output += "\n"
        }
        
        return output
    }
}
