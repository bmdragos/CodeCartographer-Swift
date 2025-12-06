import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Code Smell Analysis (Force Unwraps, Implicitly Unwrapped, etc.)

struct CodeSmellReport: Codable {
    let analyzedAt: String
    var totalSmells: Int
    var smellsByType: [String: Int]
    var smellsByFile: [String: Int]
    var smells: [CodeSmell]
    var hotspotFiles: [String]
}

struct CodeSmell: Codable {
    let file: String
    let line: Int?
    let type: SmellType
    let code: String
    let suggestion: String
    
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
        smells.append(CodeSmell(
            file: filePath,
            line: lineNumber(for: node.position),
            type: .forceUnwrap,
            code: String(code.prefix(50)),
            suggestion: "Use optional binding (if let) or nil coalescing (??)"
        ))
        return .visitChildren
    }
    
    // Detect force cast (as!)
    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let code = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .forceCast,
                code: String(code.prefix(50)),
                suggestion: "Use conditional cast (as?) with optional binding"
            ))
        }
        return .visitChildren
    }
    
    // Detect force try (try!)
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let code = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .forceTry,
                code: String(code.prefix(50)),
                suggestion: "Use do-catch or try? for error handling"
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
        
        smells.append(CodeSmell(
            file: filePath,
            line: lineNumber(for: node.position),
            type: .implicitlyUnwrapped,
            code: code,
            suggestion: "Use regular optional (?) and handle nil case"
        ))
        return .visitChildren
    }
    
    // Detect empty catch blocks
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let bodyText = node.body.statements.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if bodyText.isEmpty || bodyText == "{}" {
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .emptycatch,
                code: "catch { }",
                suggestion: "Handle or log the error, don't silently ignore"
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
            
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .printStatement,
                code: String(node.description.prefix(40)),
                suggestion: "Use proper logging framework or wrap in #if DEBUG"
            ))
        }
        
        return .visitChildren
    }
    
    // Detect long parameter lists
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let paramCount = node.signature.parameterClause.parameters.count
        if paramCount > 5 {
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .longParameterList,
                code: "func \(node.name.text)(...\(paramCount) params)",
                suggestion: "Consider using a configuration struct or builder pattern"
            ))
        }
        return .visitChildren
    }
    
    // Track nesting level
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        nestingLevel += 1
        maxNestingInFile = max(maxNestingInFile, nestingLevel)
        
        if nestingLevel > 4 {
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .deepNesting,
                code: "Nesting level: \(nestingLevel)",
                suggestion: "Extract nested logic into separate functions or use guard"
            ))
        }
        return .visitChildren
    }
    
    override func visitPost(_ node: IfExprSyntax) {
        nestingLevel -= 1
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
            smells.append(CodeSmell(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .magicNumber,
                code: value,
                suggestion: "Extract to a named constant for clarity"
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

class CodeSmellAnalyzer {
    
    func analyze(files: [URL], relativeTo root: URL) -> CodeSmellReport {
        var allSmells: [CodeSmell] = []
        var smellsByFile: [String: Int] = [:]
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = CodeSmellVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            allSmells.append(contentsOf: visitor.smells)
            if !visitor.smells.isEmpty {
                smellsByFile[relativePath] = visitor.smells.count
            }
        }
        
        // Build type counts
        var smellsByType: [String: Int] = [:]
        for smell in allSmells {
            smellsByType[smell.type.rawValue, default: 0] += 1
        }
        
        // Top hotspot files
        let hotspots = smellsByFile.sorted { $0.value > $1.value }.prefix(15).map { $0.key }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return CodeSmellReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalSmells: allSmells.count,
            smellsByType: smellsByType,
            smellsByFile: smellsByFile,
            smells: allSmells,
            hotspotFiles: Array(hotspots)
        )
    }
}
