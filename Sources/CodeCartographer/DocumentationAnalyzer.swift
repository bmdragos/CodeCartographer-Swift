import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Documentation Coverage Analysis

struct DocumentationReport: Codable {
    let analyzedAt: String
    var totalPublicSymbols: Int
    var documentedSymbols: Int
    var coveragePercentage: Double
    var undocumentedItems: [UndocumentedItem]
    var documentedItems: [DocumentedItem]
    var byType: DocumentationByType
    var recommendations: [String]
}

struct UndocumentedItem: Codable {
    let name: String
    let file: String
    let line: Int?
    let symbolType: SymbolType
    let visibility: String  // public, open, internal
    
    enum SymbolType: String, Codable {
        case `class` = "class"
        case `struct` = "struct"
        case `enum` = "enum"
        case `protocol` = "protocol"
        case function = "function"
        case property = "property"
        case initializer = "initializer"
    }
}

struct DocumentedItem: Codable {
    let name: String
    let file: String
    let hasDescription: Bool
    let hasParameters: Bool
    let hasReturns: Bool
    let hasThrows: Bool
}

struct DocumentationByType: Codable {
    var classes: DocumentationStats
    var structs: DocumentationStats
    var enums: DocumentationStats
    var protocols: DocumentationStats
    var functions: DocumentationStats
    var properties: DocumentationStats
}

struct DocumentationStats: Codable {
    var total: Int
    var documented: Int
    var percentage: Double
}

// MARK: - Documentation Visitor

final class DocumentationVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var undocumented: [UndocumentedItem] = []
    private(set) var documented: [DocumentedItem] = []
    private(set) var stats = DocumentationByType(
        classes: DocumentationStats(total: 0, documented: 0, percentage: 0),
        structs: DocumentationStats(total: 0, documented: 0, percentage: 0),
        enums: DocumentationStats(total: 0, documented: 0, percentage: 0),
        protocols: DocumentationStats(total: 0, documented: 0, percentage: 0),
        functions: DocumentationStats(total: 0, documented: 0, percentage: 0),
        properties: DocumentationStats(total: 0, documented: 0, percentage: 0)
    )
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Check for doc comment before a node
    private func hasDocComment(before node: some SyntaxProtocol) -> (hasDoc: Bool, details: DocDetails) {
        let leadingTrivia = node.leadingTrivia
        var hasDoc = false
        var hasDescription = false
        var hasParameters = false
        var hasReturns = false
        var hasThrows = false
        
        for piece in leadingTrivia {
            switch piece {
            case .docLineComment(let text), .docBlockComment(let text):
                hasDoc = true
                hasDescription = true
                if text.contains("- Parameter") || text.contains("@param") {
                    hasParameters = true
                }
                if text.contains("- Returns") || text.contains("@return") {
                    hasReturns = true
                }
                if text.contains("- Throws") || text.contains("@throws") {
                    hasThrows = true
                }
            default:
                break
            }
        }
        
        return (hasDoc, DocDetails(hasDescription: hasDescription, hasParameters: hasParameters, hasReturns: hasReturns, hasThrows: hasThrows))
    }
    
    private struct DocDetails {
        let hasDescription: Bool
        let hasParameters: Bool
        let hasReturns: Bool
        let hasThrows: Bool
    }
    
    private func getVisibility(from modifiers: DeclModifierListSyntax?) -> String {
        guard let modifiers = modifiers else { return "internal" }
        for modifier in modifiers {
            let name = modifier.name.text
            if name == "public" || name == "open" || name == "private" || name == "fileprivate" || name == "internal" {
                return name
            }
        }
        return "internal"
    }
    
    private func isPublicOrOpen(_ visibility: String) -> Bool {
        return visibility == "public" || visibility == "open"
    }
    
    // Classes
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        guard isPublicOrOpen(visibility) else { return .visitChildren }
        
        stats.classes.total += 1
        let (hasDoc, details) = hasDocComment(before: node)
        
        if hasDoc {
            stats.classes.documented += 1
            documented.append(DocumentedItem(
                name: node.name.text,
                file: filePath,
                hasDescription: details.hasDescription,
                hasParameters: false,
                hasReturns: false,
                hasThrows: false
            ))
        } else {
            undocumented.append(UndocumentedItem(
                name: node.name.text,
                file: filePath,
                line: lineNumber(for: node.position),
                symbolType: .class,
                visibility: visibility
            ))
        }
        
        return .visitChildren
    }
    
    // Structs
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        guard isPublicOrOpen(visibility) else { return .visitChildren }
        
        stats.structs.total += 1
        let (hasDoc, details) = hasDocComment(before: node)
        
        if hasDoc {
            stats.structs.documented += 1
            documented.append(DocumentedItem(
                name: node.name.text,
                file: filePath,
                hasDescription: details.hasDescription,
                hasParameters: false,
                hasReturns: false,
                hasThrows: false
            ))
        } else {
            undocumented.append(UndocumentedItem(
                name: node.name.text,
                file: filePath,
                line: lineNumber(for: node.position),
                symbolType: .struct,
                visibility: visibility
            ))
        }
        
        return .visitChildren
    }
    
    // Enums
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        guard isPublicOrOpen(visibility) else { return .visitChildren }
        
        stats.enums.total += 1
        let (hasDoc, details) = hasDocComment(before: node)
        
        if hasDoc {
            stats.enums.documented += 1
            documented.append(DocumentedItem(
                name: node.name.text,
                file: filePath,
                hasDescription: details.hasDescription,
                hasParameters: false,
                hasReturns: false,
                hasThrows: false
            ))
        } else {
            undocumented.append(UndocumentedItem(
                name: node.name.text,
                file: filePath,
                line: lineNumber(for: node.position),
                symbolType: .enum,
                visibility: visibility
            ))
        }
        
        return .visitChildren
    }
    
    // Protocols
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        guard isPublicOrOpen(visibility) else { return .visitChildren }
        
        stats.protocols.total += 1
        let (hasDoc, details) = hasDocComment(before: node)
        
        if hasDoc {
            stats.protocols.documented += 1
            documented.append(DocumentedItem(
                name: node.name.text,
                file: filePath,
                hasDescription: details.hasDescription,
                hasParameters: false,
                hasReturns: false,
                hasThrows: false
            ))
        } else {
            undocumented.append(UndocumentedItem(
                name: node.name.text,
                file: filePath,
                line: lineNumber(for: node.position),
                symbolType: .protocol,
                visibility: visibility
            ))
        }
        
        return .visitChildren
    }
    
    // Functions
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        guard isPublicOrOpen(visibility) else { return .skipChildren }
        
        stats.functions.total += 1
        let (hasDoc, details) = hasDocComment(before: node)
        
        if hasDoc {
            stats.functions.documented += 1
            documented.append(DocumentedItem(
                name: node.name.text,
                file: filePath,
                hasDescription: details.hasDescription,
                hasParameters: details.hasParameters,
                hasReturns: details.hasReturns,
                hasThrows: details.hasThrows
            ))
        } else {
            undocumented.append(UndocumentedItem(
                name: node.name.text,
                file: filePath,
                line: lineNumber(for: node.position),
                symbolType: .function,
                visibility: visibility
            ))
        }
        
        return .skipChildren
    }
    
    // Properties (only public vars)
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        guard isPublicOrOpen(visibility) else { return .skipChildren }
        
        for binding in node.bindings {
            let name = binding.pattern.description.trimmingCharacters(in: .whitespacesAndNewlines)
            stats.properties.total += 1
            let (hasDoc, details) = hasDocComment(before: node)
            
            if hasDoc {
                stats.properties.documented += 1
                documented.append(DocumentedItem(
                    name: name,
                    file: filePath,
                    hasDescription: details.hasDescription,
                    hasParameters: false,
                    hasReturns: false,
                    hasThrows: false
                ))
            } else {
                undocumented.append(UndocumentedItem(
                    name: name,
                    file: filePath,
                    line: lineNumber(for: node.position),
                    symbolType: .property,
                    visibility: visibility
                ))
            }
        }
        
        return .skipChildren
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

// MARK: - Documentation Analyzer

class DocumentationAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> DocumentationReport {
        var allUndocumented: [UndocumentedItem] = []
        var allDocumented: [DocumentedItem] = []
        var totalStats = DocumentationByType(
            classes: DocumentationStats(total: 0, documented: 0, percentage: 0),
            structs: DocumentationStats(total: 0, documented: 0, percentage: 0),
            enums: DocumentationStats(total: 0, documented: 0, percentage: 0),
            protocols: DocumentationStats(total: 0, documented: 0, percentage: 0),
            functions: DocumentationStats(total: 0, documented: 0, percentage: 0),
            properties: DocumentationStats(total: 0, documented: 0, percentage: 0)
        )
        
        for file in parsedFiles {
            let visitor = DocumentationVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            allUndocumented.append(contentsOf: visitor.undocumented)
            allDocumented.append(contentsOf: visitor.documented)
            
            // Aggregate stats
            totalStats.classes.total += visitor.stats.classes.total
            totalStats.classes.documented += visitor.stats.classes.documented
            totalStats.structs.total += visitor.stats.structs.total
            totalStats.structs.documented += visitor.stats.structs.documented
            totalStats.enums.total += visitor.stats.enums.total
            totalStats.enums.documented += visitor.stats.enums.documented
            totalStats.protocols.total += visitor.stats.protocols.total
            totalStats.protocols.documented += visitor.stats.protocols.documented
            totalStats.functions.total += visitor.stats.functions.total
            totalStats.functions.documented += visitor.stats.functions.documented
            totalStats.properties.total += visitor.stats.properties.total
            totalStats.properties.documented += visitor.stats.properties.documented
        }
        
        // Calculate percentages
        totalStats.classes.percentage = totalStats.classes.total > 0 ? Double(totalStats.classes.documented) / Double(totalStats.classes.total) * 100 : 0
        totalStats.structs.percentage = totalStats.structs.total > 0 ? Double(totalStats.structs.documented) / Double(totalStats.structs.total) * 100 : 0
        totalStats.enums.percentage = totalStats.enums.total > 0 ? Double(totalStats.enums.documented) / Double(totalStats.enums.total) * 100 : 0
        totalStats.protocols.percentage = totalStats.protocols.total > 0 ? Double(totalStats.protocols.documented) / Double(totalStats.protocols.total) * 100 : 0
        totalStats.functions.percentage = totalStats.functions.total > 0 ? Double(totalStats.functions.documented) / Double(totalStats.functions.total) * 100 : 0
        totalStats.properties.percentage = totalStats.properties.total > 0 ? Double(totalStats.properties.documented) / Double(totalStats.properties.total) * 100 : 0
        
        let totalPublic = totalStats.classes.total + totalStats.structs.total + totalStats.enums.total +
                          totalStats.protocols.total + totalStats.functions.total + totalStats.properties.total
        let totalDocumented = totalStats.classes.documented + totalStats.structs.documented + totalStats.enums.documented +
                              totalStats.protocols.documented + totalStats.functions.documented + totalStats.properties.documented
        let coverage = totalPublic > 0 ? Double(totalDocumented) / Double(totalPublic) * 100 : 0
        
        // Generate recommendations
        var recommendations: [String] = []
        
        if coverage < 50 {
            recommendations.append("Low documentation coverage (\(String(format: "%.1f", coverage))%) - prioritize public API documentation")
        }
        if totalStats.protocols.percentage < 80 && totalStats.protocols.total > 0 {
            recommendations.append("Protocols should be well-documented as they define contracts")
        }
        if totalStats.functions.total > 0 {
            let functionsWithParams = allDocumented.filter { $0.hasParameters }.count
            if Double(functionsWithParams) / Double(totalStats.functions.documented) < 0.5 {
                recommendations.append("Many documented functions missing parameter documentation")
            }
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return DocumentationReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalPublicSymbols: totalPublic,
            documentedSymbols: totalDocumented,
            coveragePercentage: coverage,
            undocumentedItems: allUndocumented,
            documentedItems: allDocumented,
            byType: totalStats,
            recommendations: recommendations
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> DocumentationReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
