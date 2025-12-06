import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Retain Cycle Detection

struct RetainCycleReport: Codable {
    let analyzedAt: String
    var potentialCycles: [PotentialRetainCycle]
    var closureCaptures: [ClosureCaptureInfo]
    var delegateIssues: [DelegateRetainIssue]
    var patterns: RetainCyclePatterns
    var riskScore: Int  // 0-100, higher = more risk
    var recommendations: [String]
}

struct PotentialRetainCycle: Codable {
    let file: String
    let line: Int?
    let cycleType: CycleType
    let description: String
    let severity: Severity
    
    enum CycleType: String, Codable {
        case strongSelfInClosure = "Strong Self in Closure"
        case strongDelegateProperty = "Strong Delegate"
        case closureStoredAsProperty = "Closure Stored as Property"
        case timerWithoutInvalidate = "Timer Without Invalidate"
        case notificationWithoutRemove = "Notification Without Remove"
        case kvoWithoutRemove = "KVO Without Remove"
    }
    
    enum Severity: String, Codable {
        case high = "high"
        case medium = "medium"
        case low = "low"
    }
}

struct ClosureCaptureInfo: Codable {
    let file: String
    let line: Int?
    let hasWeakSelf: Bool
    let hasUnownedSelf: Bool
    let capturesSelf: Bool
    let isEscaping: Bool
    let context: String  // function name or property
}

struct DelegateRetainIssue: Codable {
    let file: String
    let line: Int?
    let propertyName: String
    let isWeak: Bool
    let suggestion: String
}

struct RetainCyclePatterns: Codable {
    var closuresWithSelf: Int
    var closuresWithWeakSelf: Int
    var closuresWithUnownedSelf: Int
    var strongDelegates: Int
    var weakDelegates: Int
    var timersCreated: Int
    var timersInvalidated: Int
    var notificationsAdded: Int
    var notificationsRemoved: Int
    var escapingClosures: Int
}

// MARK: - Retain Cycle Visitor

final class RetainCycleVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var potentialCycles: [PotentialRetainCycle] = []
    private(set) var closureCaptures: [ClosureCaptureInfo] = []
    private(set) var delegateIssues: [DelegateRetainIssue] = []
    private(set) var patterns = RetainCyclePatterns(
        closuresWithSelf: 0, closuresWithWeakSelf: 0, closuresWithUnownedSelf: 0,
        strongDelegates: 0, weakDelegates: 0, timersCreated: 0, timersInvalidated: 0,
        notificationsAdded: 0, notificationsRemoved: 0, escapingClosures: 0
    )
    
    private var currentFunctionName: String?
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Track function context
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentFunctionName = node.name.text
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentFunctionName = nil
    }
    
    // Detect delegate properties
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let declText = node.description.lowercased()
        
        // Check for delegate/dataSource properties
        if declText.contains("delegate") || declText.contains("datasource") {
            let isWeak = node.modifiers.contains { $0.name.text == "weak" }
            
            for binding in node.bindings {
                let propName = binding.pattern.description.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if isWeak {
                    patterns.weakDelegates += 1
                } else {
                    patterns.strongDelegates += 1
                    
                    delegateIssues.append(DelegateRetainIssue(
                        file: filePath,
                        line: lineNumber(for: node.position),
                        propertyName: propName,
                        isWeak: false,
                        suggestion: "Add 'weak' to prevent retain cycle: weak var \(propName)"
                    ))
                    
                    potentialCycles.append(PotentialRetainCycle(
                        file: filePath,
                        line: lineNumber(for: node.position),
                        cycleType: .strongDelegateProperty,
                        description: "Delegate '\(propName)' should be weak to prevent retain cycle",
                        severity: .high
                    ))
                }
            }
        }
        
        // Check for closure properties (potential retain cycles)
        for binding in node.bindings {
            if let typeAnnotation = binding.typeAnnotation?.type.description {
                if typeAnnotation.contains("->") || typeAnnotation.contains("() ->") {
                    // This is a closure property
                    let propName = binding.pattern.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    potentialCycles.append(PotentialRetainCycle(
                        file: filePath,
                        line: lineNumber(for: node.position),
                        cycleType: .closureStoredAsProperty,
                        description: "Closure property '\(propName)' may cause retain cycle if it captures self",
                        severity: .medium
                    ))
                }
            }
        }
        
        return .visitChildren
    }
    
    // Detect closures and their capture lists
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        let closureText = node.description
        
        // Check for self references in closure
        let capturesSelf = closureText.contains("self.")
        
        // Check capture list
        var hasWeakSelf = false
        var hasUnownedSelf = false
        
        if let captureList = node.signature?.capture {
            let captureText = captureList.description
            hasWeakSelf = captureText.contains("weak self") || captureText.contains("weak `self`")
            hasUnownedSelf = captureText.contains("unowned self") || captureText.contains("unowned `self`")
        }
        
        if capturesSelf {
            patterns.closuresWithSelf += 1
            
            if hasWeakSelf {
                patterns.closuresWithWeakSelf += 1
            } else if hasUnownedSelf {
                patterns.closuresWithUnownedSelf += 1
            } else {
                // Strong capture of self - potential retain cycle
                potentialCycles.append(PotentialRetainCycle(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    cycleType: .strongSelfInClosure,
                    description: "Closure captures 'self' strongly - consider [weak self] or [unowned self]",
                    severity: .medium
                ))
            }
        }
        
        closureCaptures.append(ClosureCaptureInfo(
            file: filePath,
            line: lineNumber(for: node.position),
            hasWeakSelf: hasWeakSelf,
            hasUnownedSelf: hasUnownedSelf,
            capturesSelf: capturesSelf,
            isEscaping: false,  // Would need more context to determine
            context: currentFunctionName ?? "unknown"
        ))
        
        return .visitChildren
    }
    
    // Detect Timer, NotificationCenter patterns
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullCall = node.description
        
        // Timer detection
        if callText.contains("Timer.scheduledTimer") || callText.contains("Timer(") {
            patterns.timersCreated += 1
            
            // Check if target is self without weak reference
            if fullCall.contains("target: self") && !fullCall.contains("[weak") {
                potentialCycles.append(PotentialRetainCycle(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    cycleType: .timerWithoutInvalidate,
                    description: "Timer with strong reference to self - ensure invalidate() is called",
                    severity: .high
                ))
            }
        }
        
        if callText.contains("invalidate()") {
            patterns.timersInvalidated += 1
        }
        
        // NotificationCenter detection
        if callText.contains("NotificationCenter") && callText.contains("addObserver") {
            patterns.notificationsAdded += 1
        }
        if callText.contains("NotificationCenter") && callText.contains("removeObserver") {
            patterns.notificationsRemoved += 1
        }
        
        // @escaping closure detection
        if fullCall.contains("@escaping") {
            patterns.escapingClosures += 1
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

// MARK: - Retain Cycle Analyzer

class RetainCycleAnalyzer {
    
    func analyze(files: [URL], relativeTo root: URL) -> RetainCycleReport {
        var allCycles: [PotentialRetainCycle] = []
        var allCaptures: [ClosureCaptureInfo] = []
        var allDelegateIssues: [DelegateRetainIssue] = []
        var totalPatterns = RetainCyclePatterns(
            closuresWithSelf: 0, closuresWithWeakSelf: 0, closuresWithUnownedSelf: 0,
            strongDelegates: 0, weakDelegates: 0, timersCreated: 0, timersInvalidated: 0,
            notificationsAdded: 0, notificationsRemoved: 0, escapingClosures: 0
        )
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = RetainCycleVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            allCycles.append(contentsOf: visitor.potentialCycles)
            allCaptures.append(contentsOf: visitor.closureCaptures)
            allDelegateIssues.append(contentsOf: visitor.delegateIssues)
            
            // Aggregate patterns
            totalPatterns.closuresWithSelf += visitor.patterns.closuresWithSelf
            totalPatterns.closuresWithWeakSelf += visitor.patterns.closuresWithWeakSelf
            totalPatterns.closuresWithUnownedSelf += visitor.patterns.closuresWithUnownedSelf
            totalPatterns.strongDelegates += visitor.patterns.strongDelegates
            totalPatterns.weakDelegates += visitor.patterns.weakDelegates
            totalPatterns.timersCreated += visitor.patterns.timersCreated
            totalPatterns.timersInvalidated += visitor.patterns.timersInvalidated
            totalPatterns.notificationsAdded += visitor.patterns.notificationsAdded
            totalPatterns.notificationsRemoved += visitor.patterns.notificationsRemoved
            totalPatterns.escapingClosures += visitor.patterns.escapingClosures
        }
        
        // Calculate risk score
        var riskScore = 0
        
        // Strong delegates are high risk
        riskScore += totalPatterns.strongDelegates * 10
        
        // Closures with self but no weak/unowned
        let unsafeClosures = totalPatterns.closuresWithSelf - totalPatterns.closuresWithWeakSelf - totalPatterns.closuresWithUnownedSelf
        riskScore += unsafeClosures * 2
        
        // Timers without invalidate
        if totalPatterns.timersCreated > totalPatterns.timersInvalidated {
            riskScore += (totalPatterns.timersCreated - totalPatterns.timersInvalidated) * 5
        }
        
        // Notifications without remove
        if totalPatterns.notificationsAdded > totalPatterns.notificationsRemoved {
            riskScore += (totalPatterns.notificationsAdded - totalPatterns.notificationsRemoved) * 3
        }
        
        riskScore = min(100, riskScore)
        
        // Generate recommendations
        var recommendations: [String] = []
        
        if totalPatterns.strongDelegates > 0 {
            recommendations.append("Found \(totalPatterns.strongDelegates) strong delegate properties - add 'weak' keyword")
        }
        if unsafeClosures > 10 {
            recommendations.append("Many closures capture self strongly - review for potential retain cycles")
        }
        if totalPatterns.timersCreated > totalPatterns.timersInvalidated {
            recommendations.append("More timers created than invalidated - ensure timers are cleaned up")
        }
        if totalPatterns.notificationsAdded > totalPatterns.notificationsRemoved {
            recommendations.append("More notification observers added than removed - check for leaks")
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return RetainCycleReport(
            analyzedAt: dateFormatter.string(from: Date()),
            potentialCycles: allCycles.sorted { ($0.severity.rawValue, $0.file) < ($1.severity.rawValue, $1.file) },
            closureCaptures: allCaptures,
            delegateIssues: allDelegateIssues,
            patterns: totalPatterns,
            riskScore: riskScore,
            recommendations: recommendations
        )
    }
}
