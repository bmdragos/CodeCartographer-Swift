import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Accessibility Analysis

struct AccessibilityReport: Codable {
    let analyzedAt: String
    var totalUIElements: Int
    var elementsWithAccessibility: Int
    var accessibilityCoverage: Double
    var issues: [AccessibilityIssue]
    var accessibilityUsage: [String: Int]
    var fileStats: [String: AccessibilityFileStats]
}

struct AccessibilityIssue: Codable {
    let file: String
    let line: Int?
    let element: String
    let issue: IssueType
    let suggestion: String
    
    enum IssueType: String, Codable {
        case missingLabel
        case missingHint
        case missingIdentifier
        case imageWithoutDescription
        case buttonWithoutLabel
        case customViewWithoutTraits
    }
}

struct AccessibilityFileStats: Codable {
    let uiElementCount: Int
    let accessibilitySetCount: Int
    let coverage: Double
}

// MARK: - Accessibility Visitor

final class AccessibilityVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var issues: [AccessibilityIssue] = []
    private(set) var accessibilityUsage: [String: Int] = [:]
    private(set) var uiElementCount = 0
    private(set) var accessibilitySetCount = 0
    
    private let uiElements = [
        "UIButton", "UILabel", "UIImageView", "UITextField", "UITextView",
        "UISwitch", "UISlider", "UISegmentedControl", "UITableViewCell",
        "UICollectionViewCell", "Button", "Text", "Image", "TextField"
    ]
    
    private let accessibilityAPIs = [
        "accessibilityLabel", "accessibilityHint", "accessibilityIdentifier",
        "accessibilityTraits", "accessibilityValue", "isAccessibilityElement",
        "accessibilityElements", "accessibilityCustomActions",
        ".accessibility(", "AccessibilityChildBehavior"
    ]
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Track UI element creation
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for UI element initialization - must be the actual type name, not a substring
        // e.g., "Text(" should match but "sourceText" should not
        for element in uiElements {
            // Check if it's a direct call like "Text(" or "UIButton("
            if callText == element || callText.hasSuffix(".\(element)") {
                uiElementCount += 1
                break
            }
        }
        
        return .visitChildren
    }
    
    // Track accessibility API usage - look for actual API calls like .accessibilityLabel
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let memberName = node.declName.baseName.text
        
        // Must be an actual accessibility API, not a variable with "accessibility" in name
        // Real APIs: accessibilityLabel, accessibilityHint, accessibilityValue, etc.
        let actualAccessibilityAPIs = [
            "accessibilityLabel", "accessibilityHint", "accessibilityValue",
            "accessibilityIdentifier", "accessibilityTraits", "accessibilityFrame",
            "isAccessibilityElement", "accessibilityElementsHidden",
            "shouldGroupAccessibilityChildren", "accessibilityViewIsModal"
        ]
        
        if actualAccessibilityAPIs.contains(memberName) {
            accessibilityUsage[memberName, default: 0] += 1
            accessibilitySetCount += 1
        }
        
        return .visitChildren
    }
    
    // Detect UIImageView without accessibility
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let declText = node.description
        
        // Check for image views
        if declText.contains("UIImageView") || declText.contains("Image(") {
            uiElementCount += 1
            
            // Check if accessibility is set nearby (heuristic)
            if !declText.contains("accessibilityLabel") && !declText.contains("isAccessibilityElement") {
                // This is a simplified check - real check would need more context
            }
        }
        
        return .visitChildren
    }
    
    // Check for buttons without accessibility labels
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let classText = node.description
        
        // If it's a custom button or view
        if let inheritance = node.inheritanceClause?.description,
           inheritance.contains("UIButton") || inheritance.contains("UIControl") {
            
            if !classText.contains("accessibilityLabel") {
                issues.append(AccessibilityIssue(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    element: node.name.text,
                    issue: .buttonWithoutLabel,
                    suggestion: "Add accessibilityLabel to describe the button's action"
                ))
            }
        }
        
        // Custom views should set accessibility traits
        if let inheritance = node.inheritanceClause?.description,
           inheritance.contains("UIView") && !inheritance.contains("UIViewController") {
            
            if !classText.contains("accessibilityTraits") && !classText.contains("isAccessibilityElement") {
                issues.append(AccessibilityIssue(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    element: node.name.text,
                    issue: .customViewWithoutTraits,
                    suggestion: "Consider setting accessibilityTraits or isAccessibilityElement"
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

// MARK: - Accessibility Analyzer

class AccessibilityAnalyzer {
    
    func analyze(files: [URL], relativeTo root: URL) -> AccessibilityReport {
        var allIssues: [AccessibilityIssue] = []
        var totalUIElements = 0
        var totalAccessibilitySet = 0
        var allUsage: [String: Int] = [:]
        var fileStats: [String: AccessibilityFileStats] = [:]
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = AccessibilityVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            allIssues.append(contentsOf: visitor.issues)
            totalUIElements += visitor.uiElementCount
            totalAccessibilitySet += visitor.accessibilitySetCount
            
            for (api, count) in visitor.accessibilityUsage {
                allUsage[api, default: 0] += count
            }
            
            if visitor.uiElementCount > 0 {
                let coverage = visitor.uiElementCount > 0 ?
                    Double(visitor.accessibilitySetCount) / Double(visitor.uiElementCount) * 100 : 0
                
                fileStats[relativePath] = AccessibilityFileStats(
                    uiElementCount: visitor.uiElementCount,
                    accessibilitySetCount: visitor.accessibilitySetCount,
                    coverage: coverage
                )
            }
        }
        
        let coverage = totalUIElements > 0 ?
            Double(totalAccessibilitySet) / Double(totalUIElements) * 100 : 0
        
        let dateFormatter = ISO8601DateFormatter()
        
        return AccessibilityReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalUIElements: totalUIElements,
            elementsWithAccessibility: totalAccessibilitySet,
            accessibilityCoverage: coverage,
            issues: allIssues,
            accessibilityUsage: allUsage,
            fileStats: fileStats
        )
    }
}
