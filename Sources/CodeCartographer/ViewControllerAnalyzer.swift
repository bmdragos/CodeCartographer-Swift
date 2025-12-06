import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - View Controller Lifecycle Analysis

struct ViewControllerReport: Codable {
    let analyzedAt: String
    var totalViewControllers: Int
    var lifecycleOverrides: [String: Int]  // method -> count
    var viewControllers: [ViewControllerInfo]
    var issues: [ViewControllerIssue]
    var heavyLifecycleMethods: [HeavyLifecycleMethod]
}

struct ViewControllerInfo: Codable {
    let name: String
    let file: String
    let superclass: String?
    var overriddenMethods: [String]
    var propertyCount: Int
    var methodCount: Int
    var lineCount: Int
}

struct ViewControllerIssue: Codable {
    let file: String
    let viewController: String
    let issue: IssueType
    let description: String
    let line: Int?
    
    enum IssueType: String, Codable {
        case heavyViewDidLoad
        case networkInLifecycle
        case missingSuper
        case forceLayoutInViewDidLoad
        case asyncWithoutWeakSelf
    }
}

struct HeavyLifecycleMethod: Codable {
    let file: String
    let viewController: String
    let method: String
    let lineCount: Int
    let complexity: Int
}

// MARK: - VC Visitor

final class ViewControllerVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var viewControllers: [ViewControllerInfo] = []
    private(set) var issues: [ViewControllerIssue] = []
    private(set) var heavyMethods: [HeavyLifecycleMethod] = []
    
    private var currentVC: String?
    private var currentVCSuperclass: String?
    private var currentOverrides: [String] = []
    private var currentPropertyCount = 0
    private var currentMethodCount = 0
    private var vcStartLine: Int?
    
    private let lifecycleMethods = [
        "viewDidLoad", "viewWillAppear", "viewDidAppear",
        "viewWillDisappear", "viewDidDisappear", "viewWillLayoutSubviews",
        "viewDidLayoutSubviews", "loadView", "viewWillTransition",
        "traitCollectionDidChange", "updateViewConstraints"
    ]
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        
        // Check if it's a ViewController
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                let typeName = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if typeName.contains("ViewController") || typeName.contains("UIViewController") ||
                   typeName.contains("UITableViewController") || typeName.contains("UICollectionViewController") {
                    currentVC = name
                    currentVCSuperclass = typeName
                    currentOverrides = []
                    currentPropertyCount = 0
                    currentMethodCount = 0
                    vcStartLine = lineNumber(for: node.position)
                    break
                }
            }
        }
        
        return .visitChildren
    }
    
    override func visitPost(_ node: ClassDeclSyntax) {
        if let vc = currentVC {
            let endLine = lineNumber(for: node.endPosition) ?? 0
            let startLine = vcStartLine ?? 0
            
            viewControllers.append(ViewControllerInfo(
                name: vc,
                file: filePath,
                superclass: currentVCSuperclass,
                overriddenMethods: currentOverrides,
                propertyCount: currentPropertyCount,
                methodCount: currentMethodCount,
                lineCount: endLine - startLine
            ))
        }
        
        currentVC = nil
        currentVCSuperclass = nil
    }
    
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if currentVC != nil {
            currentPropertyCount += 1
        }
        return .visitChildren
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let vc = currentVC else { return .visitChildren }
        
        currentMethodCount += 1
        let methodName = node.name.text
        
        // Check if it's a lifecycle method
        if lifecycleMethods.contains(methodName) {
            // Check for override keyword
            let isOverride = node.modifiers.contains { $0.name.text == "override" }
            if isOverride {
                currentOverrides.append(methodName)
            }
            
            // Calculate method size
            let startLine = lineNumber(for: node.position) ?? 0
            let endLine = lineNumber(for: node.endPosition) ?? 0
            let lineCount = endLine - startLine
            
            // Check for heavy lifecycle methods
            if lineCount > 30 {
                heavyMethods.append(HeavyLifecycleMethod(
                    file: filePath,
                    viewController: vc,
                    method: methodName,
                    lineCount: lineCount,
                    complexity: 0  // Could calculate
                ))
                
                issues.append(ViewControllerIssue(
                    file: filePath,
                    viewController: vc,
                    issue: .heavyViewDidLoad,
                    description: "\(methodName) has \(lineCount) lines - consider breaking up",
                    line: startLine
                ))
            }
            
            // Check for network calls in lifecycle
            let methodBody = node.description
            if methodBody.contains("URLSession") || methodBody.contains("Alamofire") ||
               methodBody.contains(".request(") || methodBody.contains("dataTask") {
                issues.append(ViewControllerIssue(
                    file: filePath,
                    viewController: vc,
                    issue: .networkInLifecycle,
                    description: "Network call in \(methodName) - consider moving to viewModel",
                    line: startLine
                ))
            }
            
            // Check for missing super call
            if !methodBody.contains("super.\(methodName)") && methodName != "loadView" {
                issues.append(ViewControllerIssue(
                    file: filePath,
                    viewController: vc,
                    issue: .missingSuper,
                    description: "Missing super.\(methodName)() call",
                    line: startLine
                ))
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

// MARK: - VC Analyzer

class ViewControllerAnalyzer {
    
    func analyze(files: [URL], relativeTo root: URL) -> ViewControllerReport {
        var allVCs: [ViewControllerInfo] = []
        var allIssues: [ViewControllerIssue] = []
        var allHeavyMethods: [HeavyLifecycleMethod] = []
        var lifecycleOverrides: [String: Int] = [:]
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = ViewControllerVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            allVCs.append(contentsOf: visitor.viewControllers)
            allIssues.append(contentsOf: visitor.issues)
            allHeavyMethods.append(contentsOf: visitor.heavyMethods)
            
            for vc in visitor.viewControllers {
                for method in vc.overriddenMethods {
                    lifecycleOverrides[method, default: 0] += 1
                }
            }
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return ViewControllerReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalViewControllers: allVCs.count,
            lifecycleOverrides: lifecycleOverrides,
            viewControllers: allVCs.sorted { $0.lineCount > $1.lineCount },
            issues: allIssues,
            heavyLifecycleMethods: allHeavyMethods.sorted { $0.lineCount > $1.lineCount }
        )
    }
}
