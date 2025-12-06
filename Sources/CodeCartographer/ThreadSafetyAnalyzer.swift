import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Thread Safety Analysis

struct ThreadSafetyReport: Codable {
    let analyzedAt: String
    var totalIssues: Int
    var issuesByType: [String: Int]
    var issues: [ThreadSafetyIssue]
    var concurrencyPatterns: [String: Int]
    var recommendations: [String]
}

struct ThreadSafetyIssue: Codable {
    let file: String
    let line: Int?
    let issueType: IssueType
    let description: String
    let severity: Severity
    let context: String?
    
    enum IssueType: String, Codable {
        case sharedStateAccess = "Shared State Access"
        case missingMainActor = "Missing @MainActor"
        case dispatchQueueMixing = "DispatchQueue Mixing"
        case unsafePropertyAccess = "Unsafe Property Access"
        case racePotential = "Potential Race Condition"
        case blockingMainThread = "Blocking Main Thread"
        case actorIsolationViolation = "Actor Isolation Issue"
    }
    
    enum Severity: String, Codable {
        case critical
        case warning
        case info
    }
}

// MARK: - Thread Safety Visitor

final class ThreadSafetyVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var issues: [ThreadSafetyIssue] = []
    private(set) var patterns: [String: Int] = [:]
    
    private var currentContext: String?
    private var isInMainActorContext = false
    private var isInAsyncContext = false
    private var currentClassHasMainActor = false
    
    // Known shared singletons
    private let sharedSingletons = [
        "Account.sharedInstance()", "UserDefaults.standard",
        "NotificationCenter.default", "FileManager.default",
        "URLSession.shared"
    ]
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        // Check for @MainActor on class
        currentClassHasMainActor = node.attributes.contains { attr in
            attr.description.contains("@MainActor")
        }
        return .visitChildren
    }
    
    override func visitPost(_ node: ClassDeclSyntax) {
        currentClassHasMainActor = false
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        
        // Check if async
        isInAsyncContext = node.signature.effectSpecifiers?.asyncSpecifier != nil
        
        // Check for @MainActor
        isInMainActorContext = currentClassHasMainActor || node.attributes.contains { attr in
            attr.description.contains("@MainActor")
        }
        
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
        isInAsyncContext = false
        isInMainActorContext = false
    }
    
    // Detect DispatchQueue usage
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let fullExpr = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Track dispatch patterns
        if fullExpr.contains("DispatchQueue.main") {
            patterns["DispatchQueue.main", default: 0] += 1
            
            // Check for sync on main (blocking)
            if fullExpr.contains(".sync") {
                issues.append(ThreadSafetyIssue(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    issueType: .blockingMainThread,
                    description: "DispatchQueue.main.sync can cause deadlock if called from main thread",
                    severity: .critical,
                    context: currentContext
                ))
            }
        }
        
        if fullExpr.contains("DispatchQueue.global") {
            patterns["DispatchQueue.global", default: 0] += 1
        }
        
        // Check for shared singleton access in async context
        for singleton in sharedSingletons {
            if fullExpr.contains(singleton) {
                if isInAsyncContext && !isInMainActorContext {
                    issues.append(ThreadSafetyIssue(
                        file: filePath,
                        line: lineNumber(for: node.position),
                        issueType: .sharedStateAccess,
                        description: "Accessing \(singleton) from async context without @MainActor",
                        severity: .warning,
                        context: currentContext
                    ))
                }
            }
        }
        
        return .visitChildren
    }
    
    // Detect async/await patterns
    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        patterns["await", default: 0] += 1
        return .visitChildren
    }
    
    // Detect Task { } usage
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if callText == "Task" || callText.hasPrefix("Task.") {
            patterns["Task", default: 0] += 1
            
            // Check for Task without proper actor isolation
            let taskBody = node.description
            if taskBody.contains("self.") && !taskBody.contains("[weak self]") {
                issues.append(ThreadSafetyIssue(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    issueType: .actorIsolationViolation,
                    description: "Task captures self strongly - consider [weak self] or actor isolation",
                    severity: .warning,
                    context: currentContext
                ))
            }
        }
        
        // Detect MainActor.run
        if callText.contains("MainActor.run") {
            patterns["MainActor.run", default: 0] += 1
        }
        
        // Detect performSelector (legacy threading)
        if callText.contains("performSelector") {
            patterns["performSelector", default: 0] += 1
            issues.append(ThreadSafetyIssue(
                file: filePath,
                line: lineNumber(for: node.position),
                issueType: .racePotential,
                description: "performSelector is legacy - consider using async/await or DispatchQueue",
                severity: .info,
                context: currentContext
            ))
        }
        
        return .visitChildren
    }
    
    // Detect @MainActor usage
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let attrText = node.description
        if attrText.contains("@MainActor") {
            patterns["@MainActor", default: 0] += 1
        }
        if attrText.contains("@Sendable") {
            patterns["@Sendable", default: 0] += 1
        }
        if attrText.contains("nonisolated") {
            patterns["nonisolated", default: 0] += 1
        }
        return .visitChildren
    }
    
    // Detect lock usage
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        if ["NSLock", "NSRecursiveLock", "DispatchSemaphore", "OSAllocatedUnfairLock"].contains(typeName) {
            patterns[typeName, default: 0] += 1
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

// MARK: - Thread Safety Analyzer

class ThreadSafetyAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> ThreadSafetyReport {
        var allIssues: [ThreadSafetyIssue] = []
        var allPatterns: [String: Int] = [:]
        
        for file in parsedFiles {
            let visitor = ThreadSafetyVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            allIssues.append(contentsOf: visitor.issues)
            for (pattern, count) in visitor.patterns {
                allPatterns[pattern, default: 0] += count
            }
        }
        
        // Build issue type counts
        var issuesByType: [String: Int] = [:]
        for issue in allIssues {
            issuesByType[issue.issueType.rawValue, default: 0] += 1
        }
        
        // Generate recommendations
        var recommendations: [String] = []
        
        if allPatterns["DispatchQueue.main", default: 0] > 50 {
            recommendations.append("Heavy DispatchQueue.main usage - consider migrating to @MainActor")
        }
        if allPatterns["@MainActor", default: 0] < 10 && allPatterns["DispatchQueue.main", default: 0] > 20 {
            recommendations.append("Low @MainActor adoption - modern Swift concurrency recommended")
        }
        if issuesByType["Shared State Access", default: 0] > 10 {
            recommendations.append("Many shared state accesses - consider actor-based isolation")
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return ThreadSafetyReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalIssues: allIssues.count,
            issuesByType: issuesByType,
            issues: allIssues.sorted { ($0.severity.rawValue, $0.file) < ($1.severity.rawValue, $1.file) },
            concurrencyPatterns: allPatterns,
            recommendations: recommendations
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> ThreadSafetyReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
