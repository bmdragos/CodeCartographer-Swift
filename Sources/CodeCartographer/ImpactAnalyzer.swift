import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Impact Analysis
// "If I change X, what breaks?"

struct ImpactReport: Codable {
    let analyzedAt: String
    let targetSymbol: String
    var directDependents: [DependentFile]
    var transitiveDependents: [DependentFile]
    var totalImpactedFiles: Int
    var impactScore: String  // Low/Medium/High/Critical
    var safeToModify: Bool
    var warnings: [String]
}

struct DependentFile: Codable {
    let file: String
    let usageCount: Int
    let usageTypes: [String]  // "calls", "inherits", "conforms", "imports"
    let specificUsages: [SymbolUsage]
}

struct SymbolUsage: Codable {
    let line: Int?
    let usageType: String
    let context: String?
    let expression: String
}

// MARK: - Impact Visitor

final class ImpactVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    let targetSymbol: String
    
    private(set) var usages: [SymbolUsage] = []
    private(set) var usageTypes: Set<String> = []
    private var currentContext: String?
    
    init(filePath: String, sourceText: String, targetSymbol: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        self.targetSymbol = targetSymbol
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }
    
    // Check inheritance
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                let typeName = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if typeName.contains(targetSymbol) {
                    usages.append(SymbolUsage(
                        line: lineNumber(for: node.position),
                        usageType: "inherits",
                        context: node.name.text,
                        expression: "class \(node.name.text): \(typeName)"
                    ))
                    usageTypes.insert("inherits")
                }
            }
        }
        return .visitChildren
    }
    
    // Check protocol conformance
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                let typeName = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if typeName.contains(targetSymbol) {
                    usages.append(SymbolUsage(
                        line: lineNumber(for: node.position),
                        usageType: "conforms",
                        context: node.name.text,
                        expression: "struct \(node.name.text): \(typeName)"
                    ))
                    usageTypes.insert("conforms")
                }
            }
        }
        return .visitChildren
    }
    
    // Check function calls and references
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name == targetSymbol || name.contains(targetSymbol) {
            usages.append(SymbolUsage(
                line: lineNumber(for: node.position),
                usageType: "references",
                context: currentContext,
                expression: String(node.description.prefix(50))
            ))
            usageTypes.insert("references")
        }
        return .visitChildren
    }
    
    // Check member access
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let fullExpr = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberName = node.declName.baseName.text
        
        if fullExpr.contains(targetSymbol) || memberName == targetSymbol {
            let usageType = node.parent?.is(FunctionCallExprSyntax.self) == true ? "calls" : "accesses"
            usages.append(SymbolUsage(
                line: lineNumber(for: node.position),
                usageType: usageType,
                context: currentContext,
                expression: String(fullExpr.prefix(60))
            ))
            usageTypes.insert(usageType)
        }
        return .visitChildren
    }
    
    // Check type annotations
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        if typeName == targetSymbol {
            usages.append(SymbolUsage(
                line: lineNumber(for: node.position),
                usageType: "type_reference",
                context: currentContext,
                expression: typeName
            ))
            usageTypes.insert("type_reference")
        }
        return .visitChildren
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

// MARK: - Impact Analyzer

class ImpactAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile], targetSymbol: String) -> ImpactReport {
        var dependents: [DependentFile] = []
        
        for file in parsedFiles {
            let visitor = ImpactVisitor(filePath: file.relativePath, sourceText: file.sourceText, targetSymbol: targetSymbol)
            visitor.walk(file.ast)
            
            if !visitor.usages.isEmpty {
                dependents.append(DependentFile(
                    file: file.relativePath,
                    usageCount: visitor.usages.count,
                    usageTypes: Array(visitor.usageTypes),
                    specificUsages: visitor.usages
                ))
            }
        }
        
        // Calculate impact score
        let totalFiles = dependents.count
        let totalUsages = dependents.map { $0.usageCount }.reduce(0, +)
        let hasInheritance = dependents.contains { $0.usageTypes.contains("inherits") }
        
        let impactScore: String
        let safeToModify: Bool
        var warnings: [String] = []
        
        if totalFiles > 50 || hasInheritance {
            impactScore = "Critical"
            safeToModify = false
            warnings.append("High blast radius - \(totalFiles) files affected")
            if hasInheritance {
                warnings.append("Symbol is inherited - changes may break subclasses")
            }
        } else if totalFiles > 20 {
            impactScore = "High"
            safeToModify = false
            warnings.append("Significant impact - consider incremental migration")
        } else if totalFiles > 5 {
            impactScore = "Medium"
            safeToModify = true
            warnings.append("Moderate impact - review all usages before changing")
        } else {
            impactScore = "Low"
            safeToModify = true
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return ImpactReport(
            analyzedAt: dateFormatter.string(from: Date()),
            targetSymbol: targetSymbol,
            directDependents: dependents.sorted { $0.usageCount > $1.usageCount },
            transitiveDependents: [],  // Would need call graph for this
            totalImpactedFiles: totalFiles,
            impactScore: impactScore,
            safeToModify: safeToModify,
            warnings: warnings
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL, targetSymbol: String) -> ImpactReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles, targetSymbol: targetSymbol)
    }
}
