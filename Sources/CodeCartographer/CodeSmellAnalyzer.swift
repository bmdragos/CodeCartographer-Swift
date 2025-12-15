import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Code Smell Analysis (Force Unwraps, Implicitly Unwrapped, etc.)

struct CodeSmellReport: Codable {
    let analyzedAt: String
    var totalSmells: Int
    var smellsByType: [String: Int]
    var smellsBySeverity: [String: Int]
    var smellsByFile: [String: Int]
    var smells: [CodeSmell]
    var hotspotFiles: [String]
    var criticalCount: Int
    var highCount: Int
}

enum SmellSeverity: String, Codable, CaseIterable {
    case critical = "critical"
    case high = "high"
    case medium = "medium"
    case low = "low"

    var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }
}

struct CodeSmell: Codable {
    let file: String
    let line: Int?
    let type: SmellType
    let code: String
    let suggestion: String
    let severity: SmellSeverity

    enum SmellType: String, Codable {
        case forceUnwrap = "Force Unwrap (!)"
        case implicitlyUnwrapped = "Implicitly Unwrapped Optional"
        case forceCast = "Force Cast (as!)"
        case forceTry = "Force Try (try!)"
        case emptycatch = "Empty Catch Block"
        case magicNumber = "Magic Number"
        case longParameterList = "Long Parameter List"
        case deepNesting = "Deep Nesting"
        case printStatement = "Print Statement in Production"

        var severity: SmellSeverity {
            switch self {
            case .forceUnwrap, .forceCast, .forceTry:
                return .critical  // Can crash at runtime
            case .implicitlyUnwrapped, .emptycatch:
                return .high      // Likely to cause issues
            case .deepNesting, .longParameterList:
                return .medium    // Code quality / maintainability
            case .magicNumber, .printStatement:
                return .low       // Style / cleanup
            }
        }
    }
}

// MARK: - Code Smell Visitor

final class CodeSmellVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var smells: [CodeSmell] = []
    private var nestingLevel = 0
    private var maxNestingInFile = 0
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Detect force unwrap (!)
    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        let code = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = CodeSmell.SmellType.forceUnwrap
        smells.append(CodeSmell(
            file: filePath,
            line: lineNumber(for: node.position),
            type: type,
            code: String(code.prefix(50)),
            suggestion: "Use optional binding (if let) or nil coalescing (??)",
            severity: type.severity
        ))
        return .visitChildren
    }
    
    // Detect force cast (as!)
    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let code = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = CodeSmell.SmellType.forceCast
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: type,
                code: String(code.prefix(50)),
                suggestion: "Use conditional cast (as?) with optional binding",
                severity: type.severity
            ))
        }
        return .visitChildren
    }
    
    // Detect force try (try!)
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let code = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = CodeSmell.SmellType.forceTry
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: type,
                code: String(code.prefix(50)),
                suggestion: "Use do-catch or try? for error handling",
                severity: type.severity
            ))
        }
        return .visitChildren
    }
    
    // Detect implicitly unwrapped optionals
    override func visit(_ node: ImplicitlyUnwrappedOptionalTypeSyntax) -> SyntaxVisitorContinueKind {
        let code = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip IBOutlets which commonly use IUO
        if let parent = node.parent?.description, parent.contains("@IBOutlet") {
            return .visitChildren
        }

        let type = CodeSmell.SmellType.implicitlyUnwrapped
        smells.append(CodeSmell(
            file: filePath,
            line: lineNumber(for: node.position),
            type: type,
            code: code,
            suggestion: "Use regular optional (?) and handle nil case",
            severity: type.severity
        ))
        return .visitChildren
    }
    
    // Detect empty catch blocks
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let bodyText = node.body.statements.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if bodyText.isEmpty || bodyText == "{}" {
            let type = CodeSmell.SmellType.emptycatch
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: type,
                code: "catch { }",
                suggestion: "Handle or log the error, don't silently ignore",
                severity: type.severity
            ))
        }
        return .visitChildren
    }
    
    // Detect print statements
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)

        if callText == "print" || callText == "debugPrint" || callText == "dump" {
            // Skip if in DEBUG block (heuristic)
            if let parent = node.parent?.parent?.parent?.description,
               parent.contains("#if DEBUG") {
                return .visitChildren
            }

            let type = CodeSmell.SmellType.printStatement
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: type,
                code: String(node.description.prefix(40)),
                suggestion: "Use proper logging framework or wrap in #if DEBUG",
                severity: type.severity
            ))
        }

        return .visitChildren
    }
    
    // Detect long parameter lists
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let paramCount = node.signature.parameterClause.parameters.count
        if paramCount > 5 {
            let type = CodeSmell.SmellType.longParameterList
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: type,
                code: "func \(node.name.text)(...\(paramCount) params)",
                suggestion: "Consider using a configuration struct or builder pattern",
                severity: type.severity
            ))
        }
        return .visitChildren
    }
    
    // Track nesting level
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        // Check if this is an "else if" (if that's a direct child of another if's else clause)
        // In SwiftSyntax, "else if" is represented as an IfExprSyntax inside the elseBody of another IfExprSyntax
        let isElseIf = node.parent?.as(IfExprSyntax.self)?.elseBody?.as(IfExprSyntax.self) == node

        if !isElseIf {
            nestingLevel += 1
            maxNestingInFile = max(maxNestingInFile, nestingLevel)

            if nestingLevel > 4 {
                let type = CodeSmell.SmellType.deepNesting
                smells.append(CodeSmell(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    type: type,
                    code: "Nesting level: \(nestingLevel)",
                    suggestion: "Extract nested logic into separate functions or use guard",
                    severity: type.severity
                ))
            }
        }
        return .visitChildren
    }

    override func visitPost(_ node: IfExprSyntax) {
        let isElseIf = node.parent?.as(IfExprSyntax.self)?.elseBody?.as(IfExprSyntax.self) == node
        if !isElseIf {
            nestingLevel -= 1
        }
    }
    
    // Detect magic numbers
    override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let value = node.literal.text
        // Skip common acceptable values
        if ["0", "1", "2", "-1", "10", "100"].contains(value) {
            return .visitChildren
        }

        // Skip if it's in a constant declaration
        if let parent = node.parent?.parent?.description,
           parent.contains("let ") || parent.contains("static ") {
            return .visitChildren
        }

        if let intValue = Int(value), intValue > 2 {
            let type = CodeSmell.SmellType.magicNumber
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: type,
                code: value,
                suggestion: "Extract to a named constant for clarity",
                severity: type.severity
            ))
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

// MARK: - Code Smell Analyzer

class CodeSmellAnalyzer: CachingAnalyzer {
    
    /// Analyze using pre-parsed files (efficient - uses cached ASTs)
    func analyze(parsedFiles: [ParsedFile]) -> CodeSmellReport {
        var allSmells: [CodeSmell] = []
        var smellsByFile: [String: Int] = [:]

        for file in parsedFiles {
            let visitor = CodeSmellVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)  // Uses cached AST

            allSmells.append(contentsOf: visitor.smells)
            if !visitor.smells.isEmpty {
                smellsByFile[file.relativePath] = visitor.smells.count
            }
        }

        // Sort by severity (critical first), then by file/line for stable ordering
        allSmells.sort { lhs, rhs in
            if lhs.severity.sortOrder != rhs.severity.sortOrder {
                return lhs.severity.sortOrder < rhs.severity.sortOrder
            }
            if lhs.file != rhs.file {
                return lhs.file < rhs.file
            }
            return (lhs.line ?? 0) < (rhs.line ?? 0)
        }

        // Build type counts
        var smellsByType: [String: Int] = [:]
        for smell in allSmells {
            smellsByType[smell.type.rawValue, default: 0] += 1
        }

        // Build severity counts
        var smellsBySeverity: [String: Int] = [:]
        for smell in allSmells {
            smellsBySeverity[smell.severity.rawValue, default: 0] += 1
        }

        // Top hotspot files
        let hotspots = smellsByFile.sorted { $0.value > $1.value }.prefix(15).map { $0.key }

        let dateFormatter = ISO8601DateFormatter()

        return CodeSmellReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalSmells: allSmells.count,
            smellsByType: smellsByType,
            smellsBySeverity: smellsBySeverity,
            smellsByFile: smellsByFile,
            smells: allSmells,
            hotspotFiles: Array(hotspots),
            criticalCount: smellsBySeverity["critical"] ?? 0,
            highCount: smellsBySeverity["high"] ?? 0
        )
    }
    
    /// Analyze using file URLs (convenience - parses on-the-fly)
    func analyze(files: [URL], relativeTo root: URL) -> CodeSmellReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
