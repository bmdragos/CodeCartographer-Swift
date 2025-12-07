import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Property Access Analysis

struct PropertyAccessReport: Codable {
    let analyzedAt: String
    let targetType: String
    var totalAccesses: Int
    var properties: [PropertyAccessInfo]
    var accessesByFile: [String: [PropertyAccess]]
}

struct PropertyAccessInfo: Codable {
    let propertyName: String
    var readCount: Int
    var writeCount: Int
    var callCount: Int  // if it's a method
    var fileCount: Int
    var accesses: [PropertyAccess]
}

struct PropertyAccess: Codable {
    let file: String
    let line: Int?
    let accessType: AccessType
    let context: String?  // function name
    let fullExpression: String
    
    enum AccessType: String, Codable {
        case read
        case write
        case call
    }
}

// MARK: - Property Access Visitor

final class PropertyAccessVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    let targetPattern: String  // e.g., "Account.sharedInstance()" or "Account.*" for wildcard
    private let isWildcard: Bool  // true if pattern ends with ".*"
    private let wildcardPrefix: String  // e.g., "Account" if pattern is "Account.*"
    
    private(set) var accesses: [String: [PropertyAccess]] = [:]  // property -> accesses
    private var currentContext: String?
    
    init(filePath: String, sourceText: String, targetPattern: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        self.targetPattern = targetPattern
        
        // Check for wildcard pattern "ClassName.*"
        if targetPattern.hasSuffix(".*") {
            self.isWildcard = true
            self.wildcardPrefix = String(targetPattern.dropLast(2)) + "."
        } else {
            self.isWildcard = false
            self.wildcardPrefix = ""
        }
        
        super.init(viewMode: .sourceAccurate)
    }
    
    private func matchesPattern(_ expression: String) -> Bool {
        if isWildcard {
            // Match "Account.anything" or "Account.anything.more"
            return expression.contains(wildcardPrefix)
        } else {
            return expression.contains(targetPattern)
        }
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }
    
    // Detect property access: Target.property or Target.method()
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let fullExpr = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if this accesses our target (supports wildcards)
        if matchesPattern(fullExpr) {
            let propertyName = node.declName.baseName.text
            
            // Determine access type
            let accessType: PropertyAccess.AccessType
            if let parent = node.parent {
                if parent.is(FunctionCallExprSyntax.self) {
                    accessType = .call
                } else if isWriteContext(node) {
                    accessType = .write
                } else {
                    accessType = .read
                }
            } else {
                accessType = .read
            }
            
            let access = PropertyAccess(
                file: filePath,
                line: lineNumber(for: node.position),
                accessType: accessType,
                context: currentContext,
                fullExpression: String(fullExpr.prefix(100))
            )
            
            accesses[propertyName, default: []].append(access)
        }
        
        return .visitChildren
    }
    
    // Detect assignments
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let opText = node.operator.description.trimmingCharacters(in: .whitespaces)
        
        if opText == "=" || opText == "+=" || opText == "-=" {
            let leftSide = node.leftOperand.description.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if matchesPattern(leftSide) {
                // Extract property name from left side
                if let lastDot = leftSide.lastIndex(of: ".") {
                    let propertyName = String(leftSide[leftSide.index(after: lastDot)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    let access = PropertyAccess(
                        file: filePath,
                        line: lineNumber(for: node.position),
                        accessType: .write,
                        context: currentContext,
                        fullExpression: String(node.description.prefix(100))
                    )
                    
                    accesses[propertyName, default: []].append(access)
                }
            }
        }
        
        return .visitChildren
    }
    
    private func isWriteContext(_ node: MemberAccessExprSyntax) -> Bool {
        // Check if this is on the left side of an assignment
        if let parent = node.parent?.as(InfixOperatorExprSyntax.self) {
            let op = parent.operator.description.trimmingCharacters(in: .whitespaces)
            if op == "=" || op == "+=" || op == "-=" {
                // Check if we're on the left side
                return parent.leftOperand.description.contains(node.description)
            }
        }
        return false
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

// MARK: - Property Access Analyzer

class PropertyAccessAnalyzer {
    
    /// Analyze property accesses matching a pattern
    /// - Parameters:
    ///   - parsedFiles: Files to analyze
    ///   - targetPattern: Pattern like "Account.*" or "Manager.shared"
    ///   - filterProperty: Optional - only include accesses to this specific property (e.g., "tokens", "email")
    func analyze(parsedFiles: [ParsedFile], targetPattern: String, filterProperty: String? = nil) -> PropertyAccessReport {
        var allAccesses: [String: [PropertyAccess]] = [:]
        var accessesByFile: [String: [PropertyAccess]] = [:]
        
        for file in parsedFiles {
            let visitor = PropertyAccessVisitor(
                filePath: file.relativePath,
                sourceText: file.sourceText,
                targetPattern: targetPattern
            )
            visitor.walk(file.ast)
            
            // Merge accesses (with optional property filter)
            for (prop, propAccesses) in visitor.accesses {
                // Filter by property name if specified
                if let filter = filterProperty {
                    // Support wildcards in filter: "token*" matches "tokens", "tokenModel", etc.
                    let matches: Bool
                    if filter.hasSuffix("*") {
                        let prefix = String(filter.dropLast())
                        matches = prop.lowercased().hasPrefix(prefix.lowercased())
                    } else if filter.hasPrefix("*") {
                        let suffix = String(filter.dropFirst())
                        matches = prop.lowercased().hasSuffix(suffix.lowercased())
                    } else {
                        matches = prop.lowercased() == filter.lowercased()
                    }
                    
                    if !matches { continue }
                }
                
                allAccesses[prop, default: []].append(contentsOf: propAccesses)
            }
            
            // Track by file (with filter applied)
            var fileAccesses: [PropertyAccess] = []
            for (prop, propAccesses) in visitor.accesses {
                if let filter = filterProperty {
                    let matches: Bool
                    if filter.hasSuffix("*") {
                        let prefix = String(filter.dropLast())
                        matches = prop.lowercased().hasPrefix(prefix.lowercased())
                    } else if filter.hasPrefix("*") {
                        let suffix = String(filter.dropFirst())
                        matches = prop.lowercased().hasSuffix(suffix.lowercased())
                    } else {
                        matches = prop.lowercased() == filter.lowercased()
                    }
                    if matches {
                        fileAccesses.append(contentsOf: propAccesses)
                    }
                } else {
                    fileAccesses.append(contentsOf: propAccesses)
                }
            }
            if !fileAccesses.isEmpty {
                accessesByFile[file.relativePath] = fileAccesses
            }
        }
        
        // Build property info
        var properties: [PropertyAccessInfo] = []
        for (propName, propAccesses) in allAccesses {
            let reads = propAccesses.filter { $0.accessType == .read }.count
            let writes = propAccesses.filter { $0.accessType == .write }.count
            let calls = propAccesses.filter { $0.accessType == .call }.count
            let files = Set(propAccesses.map { $0.file }).count
            
            properties.append(PropertyAccessInfo(
                propertyName: propName,
                readCount: reads,
                writeCount: writes,
                callCount: calls,
                fileCount: files,
                accesses: propAccesses
            ))
        }
        
        let dateFormatter = ISO8601DateFormatter()
        let reportType = filterProperty != nil ? "\(targetPattern) → \(filterProperty!)" : targetPattern
        
        return PropertyAccessReport(
            analyzedAt: dateFormatter.string(from: Date()),
            targetType: reportType,
            totalAccesses: allAccesses.values.flatMap { $0 }.count,
            properties: properties.sorted { $0.readCount + $0.writeCount + $0.callCount > $1.readCount + $1.writeCount + $1.callCount },
            accessesByFile: accessesByFile
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL, targetPattern: String, filterProperty: String? = nil) -> PropertyAccessReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles, targetPattern: targetPattern, filterProperty: filterProperty)
    }
}
