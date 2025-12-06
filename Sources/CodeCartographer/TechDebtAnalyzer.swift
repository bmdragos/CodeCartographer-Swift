import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Tech Debt Analysis

struct TechDebtReport: Codable {
    let analyzedAt: String
    var totalMarkers: Int
    var markersByType: [String: Int]
    var markersByFile: [String: Int]
    var items: [TechDebtItem]
    var hotspotFiles: [String]  // files with most debt markers
}

struct TechDebtItem: Codable {
    let file: String
    let line: Int
    let type: DebtType
    let content: String
    let context: String?  // function name if available
    
    enum DebtType: String, Codable {
        case todo = "TODO"
        case fixme = "FIXME"
        case hack = "HACK"
        case warning = "WARNING"
        case bug = "BUG"
        case note = "NOTE"
        case optimize = "OPTIMIZE"
        case deprecated = "DEPRECATED"
    }
}

// MARK: - Function Metrics

struct FunctionMetricsReport: Codable {
    let analyzedAt: String
    var totalFunctions: Int
    var averageLineCount: Double
    var averageComplexity: Double
    var functions: [FunctionMetric]
    var godFunctions: [FunctionMetric]  // functions > 50 lines or complexity > 10
    var fileMetrics: [FileMetric]
}

struct FunctionMetric: Codable {
    let file: String
    let name: String
    let line: Int?
    let lineCount: Int
    let complexity: Int  // cyclomatic complexity (branches)
    let parameterCount: Int
    let isAsync: Bool
    let hasThrows: Bool
}

struct FileMetric: Codable {
    let file: String
    let totalLines: Int
    let functionCount: Int
    let classCount: Int
    let averageFunctionLength: Double
}

// MARK: - Tech Debt Scanner

class TechDebtAnalyzer {
    
    private let patterns: [(String, TechDebtItem.DebtType)] = [
        ("TODO:", .todo),
        ("TODO(", .todo),
        ("FIXME:", .fixme),
        ("FIXME(", .fixme),
        ("HACK:", .hack),
        ("HACK(", .hack),
        ("WARNING:", .warning),
        ("BUG:", .bug),
        ("NOTE:", .note),
        ("OPTIMIZE:", .optimize),
        ("DEPRECATED:", .deprecated),
        ("XXX:", .hack),
        ("TEMP:", .hack),
        ("TEMPORARY:", .hack),
    ]
    
    func analyze(parsedFiles: [ParsedFile]) -> TechDebtReport {
        var items: [TechDebtItem] = []
        
        for file in parsedFiles {
            let lines = file.sourceText.components(separatedBy: .newlines)
            var currentFunction: String? = nil
            
            for (index, line) in lines.enumerated() {
                let lineNum = index + 1
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                // Track function context (simple heuristic)
                if trimmed.contains("func ") {
                    if let funcMatch = trimmed.range(of: #"func\s+(\w+)"#, options: .regularExpression) {
                        let afterFunc = trimmed[funcMatch].dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let parenIndex = afterFunc.firstIndex(of: "(") {
                            currentFunction = String(afterFunc[..<parenIndex])
                        }
                    }
                }
                
                // Check for debt markers in comments
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    for (pattern, debtType) in patterns {
                        if line.uppercased().contains(pattern) {
                            // Extract the content after the marker
                            let content = extractDebtContent(from: line, marker: pattern)
                            items.append(TechDebtItem(
                                file: file.relativePath,
                                line: lineNum,
                                type: debtType,
                                content: content,
                                context: currentFunction
                            ))
                            break
                        }
                    }
                }
            }
        }
        
        // Build summaries
        var markersByType: [String: Int] = [:]
        var markersByFile: [String: Int] = [:]
        
        for item in items {
            markersByType[item.type.rawValue, default: 0] += 1
            markersByFile[item.file, default: 0] += 1
        }
        
        let hotspots = markersByFile.sorted { $0.value > $1.value }.prefix(10).map { $0.key }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return TechDebtReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalMarkers: items.count,
            markersByType: markersByType,
            markersByFile: markersByFile,
            items: items.sorted { ($0.file, $0.line) < ($1.file, $1.line) },
            hotspotFiles: Array(hotspots)
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> TechDebtReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
    
    private func extractDebtContent(from line: String, marker: String) -> String {
        guard let range = line.uppercased().range(of: marker) else { return line }
        let afterMarker = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // Clean up common suffixes
        return String(afterMarker.prefix(200))
            .trimmingCharacters(in: CharacterSet(charactersIn: "*/"))
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Function Metrics Visitor

final class FunctionMetricsVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var functions: [FunctionMetric] = []
    private(set) var classCount = 0
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        classCount += 1
        return .visitChildren
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let startLine = lineNumber(for: node.position)
        let endLine = lineNumber(for: node.endPosition)
        let lineCount = (endLine ?? 0) - (startLine ?? 0) + 1
        
        // Count parameters
        let paramCount = node.signature.parameterClause.parameters.count
        
        // Calculate cyclomatic complexity (count branches)
        let complexityVisitor = ComplexityVisitor(viewMode: .sourceAccurate)
        complexityVisitor.walk(node)
        let complexity = complexityVisitor.complexity + 1  // Base complexity is 1
        
        // Check modifiers
        let isAsync = node.signature.effectSpecifiers?.asyncSpecifier != nil
        let hasThrows = node.signature.effectSpecifiers?.throwsSpecifier != nil
        
        functions.append(FunctionMetric(
            file: filePath,
            name: name,
            line: startLine,
            lineCount: lineCount,
            complexity: complexity,
            parameterCount: paramCount,
            isAsync: isAsync,
            hasThrows: hasThrows
        ))
        
        return .skipChildren  // Don't count nested functions separately
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

// MARK: - Complexity Counter

final class ComplexityVisitor: SyntaxVisitor {
    var complexity = 0
    
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }
    
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // Count && and || as branches
        let op = node.operator.description.trimmingCharacters(in: .whitespaces)
        if op == "&&" || op == "||" || op == "??" {
            complexity += 1
        }
        return .visitChildren
    }
}

// MARK: - Function Metrics Analyzer

class FunctionMetricsAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> FunctionMetricsReport {
        var allFunctions: [FunctionMetric] = []
        var fileMetrics: [FileMetric] = []
        
        for file in parsedFiles {
            let visitor = FunctionMetricsVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            allFunctions.append(contentsOf: visitor.functions)
            
            let totalLines = file.sourceText.components(separatedBy: .newlines).count
            let avgLength = visitor.functions.isEmpty ? 0 : 
                Double(visitor.functions.map { $0.lineCount }.reduce(0, +)) / Double(visitor.functions.count)
            
            fileMetrics.append(FileMetric(
                file: file.relativePath,
                totalLines: totalLines,
                functionCount: visitor.functions.count,
                classCount: visitor.classCount,
                averageFunctionLength: avgLength
            ))
        }
        
        // Calculate averages
        let avgLineCount = allFunctions.isEmpty ? 0 :
            Double(allFunctions.map { $0.lineCount }.reduce(0, +)) / Double(allFunctions.count)
        let avgComplexity = allFunctions.isEmpty ? 0 :
            Double(allFunctions.map { $0.complexity }.reduce(0, +)) / Double(allFunctions.count)
        
        // Find god functions (> 50 lines or complexity > 10)
        let godFunctions = allFunctions.filter { $0.lineCount > 50 || $0.complexity > 10 }
            .sorted { $0.lineCount + $0.complexity * 5 > $1.lineCount + $1.complexity * 5 }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return FunctionMetricsReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalFunctions: allFunctions.count,
            averageLineCount: avgLineCount,
            averageComplexity: avgComplexity,
            functions: allFunctions.sorted { $0.lineCount > $1.lineCount },
            godFunctions: godFunctions,
            fileMetrics: fileMetrics.sorted { $0.totalLines > $1.totalLines }
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> FunctionMetricsReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
