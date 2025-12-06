import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - RxSwift/Combine Analysis

struct ReactiveReport: Codable {
    let analyzedAt: String
    var framework: String  // "RxSwift", "Combine", or "Both"
    var totalSubscriptions: Int
    var totalDisposeBags: Int
    var totalPublishers: Int
    var subscriptions: [SubscriptionInfo]
    var potentialLeaks: [PotentialLeak]
    var reactiveFileStats: [String: ReactiveFileStats]
}

struct SubscriptionInfo: Codable {
    let file: String
    let line: Int?
    let type: SubscriptionType
    let context: String?
    let hasDisposal: Bool
    
    enum SubscriptionType: String, Codable {
        case rxSubscribe = "subscribe"
        case rxBind = "bind"
        case rxDrive = "drive"
        case combineSink = "sink"
        case combineAssign = "assign"
        case combineReceive = "receive"
    }
}

struct PotentialLeak: Codable {
    let file: String
    let line: Int?
    let issue: LeakType
    let description: String
    
    enum LeakType: String, Codable {
        case missingDisposeBag
        case strongSelfInClosure
        case subscribeWithoutDisposal
        case missingCancellable
    }
}

struct ReactiveFileStats: Codable {
    let subscriptionCount: Int
    let disposeBagCount: Int
    let hasStrongSelfWarnings: Int
}

// MARK: - Reactive Visitor

final class ReactiveVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var subscriptions: [SubscriptionInfo] = []
    private(set) var disposeBagCount = 0
    private(set) var cancellableCount = 0
    private(set) var potentialLeaks: [PotentialLeak] = []
    private(set) var usesRxSwift = false
    private(set) var usesCombine = false
    
    private var currentContext: String?
    private var currentHasDisposeBag = false
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        currentHasDisposeBag = false
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }
    
    // Detect DisposeBag declarations
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let declText = node.description
        
        if declText.contains("DisposeBag") {
            disposeBagCount += 1
            currentHasDisposeBag = true
            usesRxSwift = true
        }
        
        if declText.contains("AnyCancellable") || declText.contains("Set<AnyCancellable>") {
            cancellableCount += 1
            usesCombine = true
        }
        
        return .visitChildren
    }
    
    // Detect subscriptions and bindings
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // RxSwift patterns
        if callText.hasSuffix(".subscribe") || callText.contains(".subscribe(") {
            usesRxSwift = true
            let hasDisposal = checkForDisposal(in: node)
            subscriptions.append(SubscriptionInfo(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .rxSubscribe,
                context: currentContext,
                hasDisposal: hasDisposal
            ))
            
            if !hasDisposal && !currentHasDisposeBag {
                potentialLeaks.append(PotentialLeak(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    issue: .subscribeWithoutDisposal,
                    description: "subscribe() without .disposed(by:) - potential memory leak"
                ))
            }
        }
        
        if callText.hasSuffix(".bind") || callText.contains(".bind(") {
            usesRxSwift = true
            subscriptions.append(SubscriptionInfo(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .rxBind,
                context: currentContext,
                hasDisposal: checkForDisposal(in: node)
            ))
        }
        
        if callText.hasSuffix(".drive") || callText.contains(".drive(") {
            usesRxSwift = true
            subscriptions.append(SubscriptionInfo(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .rxDrive,
                context: currentContext,
                hasDisposal: checkForDisposal(in: node)
            ))
        }
        
        // Combine patterns
        if callText.hasSuffix(".sink") || callText.contains(".sink(") {
            usesCombine = true
            subscriptions.append(SubscriptionInfo(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .combineSink,
                context: currentContext,
                hasDisposal: true  // Combine requires storing cancellable
            ))
        }
        
        if callText.hasSuffix(".assign") || callText.contains(".assign(") {
            usesCombine = true
            subscriptions.append(SubscriptionInfo(
                file: filePath,
                line: lineNumber(for: node.position),
                type: .combineAssign,
                context: currentContext,
                hasDisposal: true
            ))
        }
        
        return .visitChildren
    }
    
    // Detect strong self in closures
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        let closureText = node.description
        
        // Check for [weak self] or [unowned self]
        let hasWeakSelf = closureText.contains("[weak self]") || closureText.contains("[unowned self]")
        
        // Check if self is used in the closure
        let usesSelf = closureText.contains("self.") || closureText.contains("self,")
        
        if usesSelf && !hasWeakSelf {
            // Check if this is inside a subscription
            if let parent = node.parent?.description,
               parent.contains(".subscribe") || parent.contains(".sink") || parent.contains(".bind") {
                potentialLeaks.append(PotentialLeak(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    issue: .strongSelfInClosure,
                    description: "Strong self reference in reactive closure - potential retain cycle"
                ))
            }
        }
        
        return .visitChildren
    }
    
    private func checkForDisposal(in node: FunctionCallExprSyntax) -> Bool {
        // Check if there's a .disposed(by:) chained
        if let parent = node.parent?.description {
            return parent.contains(".disposed(by:)") || parent.contains("disposeBag")
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

// MARK: - Reactive Analyzer

class ReactiveAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> ReactiveReport {
        var allSubscriptions: [SubscriptionInfo] = []
        var allLeaks: [PotentialLeak] = []
        var totalDisposeBags = 0
        var totalCancellables = 0
        var fileStats: [String: ReactiveFileStats] = [:]
        var usesRxSwift = false
        var usesCombine = false
        
        for file in parsedFiles {
            let visitor = ReactiveVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            if visitor.usesRxSwift { usesRxSwift = true }
            if visitor.usesCombine { usesCombine = true }
            
            allSubscriptions.append(contentsOf: visitor.subscriptions)
            allLeaks.append(contentsOf: visitor.potentialLeaks)
            totalDisposeBags += visitor.disposeBagCount
            totalCancellables += visitor.cancellableCount
            
            if !visitor.subscriptions.isEmpty || visitor.disposeBagCount > 0 {
                fileStats[file.relativePath] = ReactiveFileStats(
                    subscriptionCount: visitor.subscriptions.count,
                    disposeBagCount: visitor.disposeBagCount,
                    hasStrongSelfWarnings: visitor.potentialLeaks.filter { $0.issue == .strongSelfInClosure }.count
                )
            }
        }
        
        let framework: String
        if usesRxSwift && usesCombine {
            framework = "Both"
        } else if usesRxSwift {
            framework = "RxSwift"
        } else if usesCombine {
            framework = "Combine"
        } else {
            framework = "None"
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return ReactiveReport(
            analyzedAt: dateFormatter.string(from: Date()),
            framework: framework,
            totalSubscriptions: allSubscriptions.count,
            totalDisposeBags: totalDisposeBags,
            totalPublishers: totalCancellables,
            subscriptions: allSubscriptions,
            potentialLeaks: allLeaks,
            reactiveFileStats: fileStats
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> ReactiveReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
