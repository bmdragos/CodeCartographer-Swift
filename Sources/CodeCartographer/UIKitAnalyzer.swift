import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - UIKit Pattern Analysis

struct UIKitReport: Codable {
    let analyzedAt: String
    var totalUIKitFiles: Int
    var viewControllers: [UIKitViewControllerInfo]
    var views: [UIKitViewInfo]
    var patterns: UIKitPatterns
    var storyboardUsage: StoryboardUsage
    var issues: [UIKitIssue]
    var modernizationScore: Int  // 0-100, higher = more modern
}

struct UIKitViewControllerInfo: Codable {
    let name: String
    let file: String
    let superclass: String
    var lineCount: Int
    var ibOutletCount: Int
    var ibActionCount: Int
    var usesStoryboard: Bool
    var usesAutoLayout: Bool
    var usesSnapKit: Bool
}

struct UIKitViewInfo: Codable {
    let name: String
    let file: String
    let superclass: String
    var isCustomView: Bool
    var usesAutoLayout: Bool
    var drawsManually: Bool  // overrides draw()
}

struct UIKitPatterns: Codable {
    var ibOutlets: Int
    var ibActions: Int
    var autoLayoutConstraints: Int
    var snapKitUsage: Int
    var frameBasedLayout: Int
    var delegatePatterns: Int
    var notificationCenterUsage: Int
    var targetActionPatterns: Int
    var gestureRecognizers: Int
    var tableViewUsage: Int
    var collectionViewUsage: Int
    var navigationControllerUsage: Int
    var tabBarControllerUsage: Int
    var alertControllerUsage: Int
    var presentUsage: Int
    var pushUsage: Int
    var performSegueUsage: Int
}

struct StoryboardUsage: Codable {
    var storyboardInstantiations: Int
    var segueUsage: Int
    var ibSegueIdentifiers: [String]
    var programmaticNavigation: Int
}

struct UIKitIssue: Codable {
    let file: String
    let line: Int?
    let issue: IssueType
    let description: String
    
    enum IssueType: String, Codable {
        case massiveViewController = "Massive View Controller"
        case frameBasedLayout = "Frame-Based Layout"
        case forcedUnwrapOutlet = "Force Unwrapped IBOutlet"
        case missingWeakDelegate = "Missing Weak Delegate"
        case deprecatedAPI = "Deprecated API"
        case noAutoLayout = "No Auto Layout"
    }
}

// MARK: - UIKit Visitor

final class UIKitVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var viewControllers: [UIKitViewControllerInfo] = []
    private(set) var views: [UIKitViewInfo] = []
    private(set) var patterns = UIKitPatterns(
        ibOutlets: 0, ibActions: 0, autoLayoutConstraints: 0,
        snapKitUsage: 0, frameBasedLayout: 0, delegatePatterns: 0,
        notificationCenterUsage: 0, targetActionPatterns: 0,
        gestureRecognizers: 0, tableViewUsage: 0, collectionViewUsage: 0,
        navigationControllerUsage: 0, tabBarControllerUsage: 0,
        alertControllerUsage: 0, presentUsage: 0, pushUsage: 0,
        performSegueUsage: 0
    )
    private(set) var storyboard = StoryboardUsage(
        storyboardInstantiations: 0, segueUsage: 0,
        ibSegueIdentifiers: [], programmaticNavigation: 0
    )
    private(set) var issues: [UIKitIssue] = []
    private(set) var hasUIKit = false
    
    private var currentClassName: String?
    private var currentSuperclass: String?
    private var currentClassStartLine: Int?
    private var currentIBOutletCount = 0
    private var currentIBActionCount = 0
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Detect UIKit import
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let importName = node.path.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if importName == "UIKit" {
            hasUIKit = true
        }
        if importName == "SnapKit" {
            patterns.snapKitUsage += 1
        }
        return .skipChildren
    }
    
    // Detect classes
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        currentClassName = node.name.text
        currentClassStartLine = lineNumber(for: node.position)
        currentIBOutletCount = 0
        currentIBActionCount = 0
        
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                let typeName = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                currentSuperclass = typeName
                
                // ViewController detection
                if typeName.contains("ViewController") || typeName.contains("UIViewController") ||
                   typeName.contains("UITableViewController") || typeName.contains("UICollectionViewController") ||
                   typeName.contains("UINavigationController") || typeName.contains("UITabBarController") {
                    // Will be added in visitPost
                }
                
                // View detection
                if typeName == "UIView" || typeName.hasSuffix("View") && !typeName.contains("Controller") {
                    // Will be added in visitPost
                }
            }
        }
        
        return .visitChildren
    }
    
    override func visitPost(_ node: ClassDeclSyntax) {
        guard let className = currentClassName, let superclass = currentSuperclass else {
            currentClassName = nil
            currentSuperclass = nil
            return
        }
        
        let endLine = lineNumber(for: node.endPosition) ?? 0
        let startLine = currentClassStartLine ?? 0
        let lineCount = endLine - startLine
        
        // Check if it's a ViewController
        if superclass.contains("ViewController") || superclass.contains("Controller") {
            let vcInfo = UIKitViewControllerInfo(
                name: className,
                file: filePath,
                superclass: superclass,
                lineCount: lineCount,
                ibOutletCount: currentIBOutletCount,
                ibActionCount: currentIBActionCount,
                usesStoryboard: storyboard.storyboardInstantiations > 0 || storyboard.segueUsage > 0,
                usesAutoLayout: patterns.autoLayoutConstraints > 0,
                usesSnapKit: patterns.snapKitUsage > 0
            )
            viewControllers.append(vcInfo)
            
            // Check for massive VC
            if lineCount > 500 {
                issues.append(UIKitIssue(
                    file: filePath,
                    line: startLine,
                    issue: .massiveViewController,
                    description: "\(className) has \(lineCount) lines - consider breaking into smaller components"
                ))
            }
        }
        
        // Check if it's a View
        if superclass == "UIView" || (superclass.hasSuffix("View") && !superclass.contains("Controller")) {
            views.append(UIKitViewInfo(
                name: className,
                file: filePath,
                superclass: superclass,
                isCustomView: true,
                usesAutoLayout: patterns.autoLayoutConstraints > 0,
                drawsManually: false  // Would need to check for draw() override
            ))
        }
        
        currentClassName = nil
        currentSuperclass = nil
    }
    
    // Detect IBOutlet/IBAction
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let attrText = node.description
        
        if attrText.contains("@IBOutlet") {
            patterns.ibOutlets += 1
            currentIBOutletCount += 1
        }
        if attrText.contains("@IBAction") {
            patterns.ibActions += 1
            currentIBActionCount += 1
        }
        if attrText.contains("@objc") {
            patterns.targetActionPatterns += 1
        }
        
        return .visitChildren
    }
    
    // Detect UIKit patterns in function calls
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Auto Layout
        if callText.contains("NSLayoutConstraint") || callText.contains("activate") ||
           callText.contains("addConstraint") || callText.contains("translatesAutoresizingMaskIntoConstraints") {
            patterns.autoLayoutConstraints += 1
        }
        
        // SnapKit
        if callText.contains("snp.") || callText.contains("makeConstraints") ||
           callText.contains("updateConstraints") || callText.contains("remakeConstraints") {
            patterns.snapKitUsage += 1
        }
        
        // Frame-based layout
        if callText.contains(".frame") || callText.contains("CGRect(") {
            patterns.frameBasedLayout += 1
        }
        
        // Navigation
        if callText.contains("present(") || callText.contains("present(animated") {
            patterns.presentUsage += 1
            storyboard.programmaticNavigation += 1
        }
        if callText.contains("pushViewController") {
            patterns.pushUsage += 1
            storyboard.programmaticNavigation += 1
        }
        if callText.contains("performSegue") {
            patterns.performSegueUsage += 1
            storyboard.segueUsage += 1
        }
        
        // Storyboard
        if callText.contains("instantiateViewController") || callText.contains("UIStoryboard") {
            storyboard.storyboardInstantiations += 1
        }
        
        // UIKit components
        if callText.contains("UITableView") {
            patterns.tableViewUsage += 1
        }
        if callText.contains("UICollectionView") {
            patterns.collectionViewUsage += 1
        }
        if callText.contains("UIAlertController") {
            patterns.alertControllerUsage += 1
        }
        if callText.contains("UIGestureRecognizer") || callText.contains("TapGestureRecognizer") ||
           callText.contains("SwipeGestureRecognizer") || callText.contains("PanGestureRecognizer") {
            patterns.gestureRecognizers += 1
        }
        if callText.contains("NotificationCenter") {
            patterns.notificationCenterUsage += 1
        }
        if callText.contains("addTarget") {
            patterns.targetActionPatterns += 1
        }
        
        return .visitChildren
    }
    
    // Detect delegate patterns
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                let lowerName = name.lowercased()
                // Check if property NAME is a delegate (not just contains "delegate" anywhere)
                let isDelegateProperty = lowerName == "delegate" || 
                                         lowerName == "datasource" ||
                                         lowerName.hasSuffix("delegate") ||
                                         lowerName.hasSuffix("datasource")
                
                if isDelegateProperty {
                    patterns.delegatePatterns += 1
                }
            }
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

// MARK: - UIKit Analyzer

class UIKitAnalyzer {
    
    func analyze(files: [URL], relativeTo root: URL) -> UIKitReport {
        var allVCs: [UIKitViewControllerInfo] = []
        var allViews: [UIKitViewInfo] = []
        var totalPatterns = UIKitPatterns(
            ibOutlets: 0, ibActions: 0, autoLayoutConstraints: 0,
            snapKitUsage: 0, frameBasedLayout: 0, delegatePatterns: 0,
            notificationCenterUsage: 0, targetActionPatterns: 0,
            gestureRecognizers: 0, tableViewUsage: 0, collectionViewUsage: 0,
            navigationControllerUsage: 0, tabBarControllerUsage: 0,
            alertControllerUsage: 0, presentUsage: 0, pushUsage: 0,
            performSegueUsage: 0
        )
        var totalStoryboard = StoryboardUsage(
            storyboardInstantiations: 0, segueUsage: 0,
            ibSegueIdentifiers: [], programmaticNavigation: 0
        )
        var allIssues: [UIKitIssue] = []
        var uikitFileCount = 0
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = UIKitVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            if visitor.hasUIKit {
                uikitFileCount += 1
            }
            
            allVCs.append(contentsOf: visitor.viewControllers)
            allViews.append(contentsOf: visitor.views)
            allIssues.append(contentsOf: visitor.issues)
            
            // Aggregate patterns
            totalPatterns.ibOutlets += visitor.patterns.ibOutlets
            totalPatterns.ibActions += visitor.patterns.ibActions
            totalPatterns.autoLayoutConstraints += visitor.patterns.autoLayoutConstraints
            totalPatterns.snapKitUsage += visitor.patterns.snapKitUsage
            totalPatterns.frameBasedLayout += visitor.patterns.frameBasedLayout
            totalPatterns.delegatePatterns += visitor.patterns.delegatePatterns
            totalPatterns.notificationCenterUsage += visitor.patterns.notificationCenterUsage
            totalPatterns.targetActionPatterns += visitor.patterns.targetActionPatterns
            totalPatterns.gestureRecognizers += visitor.patterns.gestureRecognizers
            totalPatterns.tableViewUsage += visitor.patterns.tableViewUsage
            totalPatterns.collectionViewUsage += visitor.patterns.collectionViewUsage
            totalPatterns.alertControllerUsage += visitor.patterns.alertControllerUsage
            totalPatterns.presentUsage += visitor.patterns.presentUsage
            totalPatterns.pushUsage += visitor.patterns.pushUsage
            totalPatterns.performSegueUsage += visitor.patterns.performSegueUsage
            
            totalStoryboard.storyboardInstantiations += visitor.storyboard.storyboardInstantiations
            totalStoryboard.segueUsage += visitor.storyboard.segueUsage
            totalStoryboard.programmaticNavigation += visitor.storyboard.programmaticNavigation
        }
        
        // Calculate modernization score (0-100)
        var score = 50  // Base score
        
        // Positive factors
        if totalPatterns.autoLayoutConstraints > totalPatterns.frameBasedLayout {
            score += 15
        }
        if totalPatterns.snapKitUsage > 0 {
            score += 10
        }
        if totalStoryboard.programmaticNavigation > totalStoryboard.segueUsage {
            score += 10
        }
        
        // Negative factors
        let massiveVCs = allVCs.filter { $0.lineCount > 500 }.count
        if massiveVCs > 5 {
            score -= 15
        } else if massiveVCs > 0 {
            score -= 5
        }
        
        if totalPatterns.frameBasedLayout > 100 {
            score -= 10
        }
        
        score = max(0, min(100, score))
        
        let dateFormatter = ISO8601DateFormatter()
        
        return UIKitReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalUIKitFiles: uikitFileCount,
            viewControllers: allVCs.sorted { $0.lineCount > $1.lineCount },
            views: allViews,
            patterns: totalPatterns,
            storyboardUsage: totalStoryboard,
            issues: allIssues,
            modernizationScore: score
        )
    }
}
