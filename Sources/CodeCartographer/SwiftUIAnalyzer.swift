import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - SwiftUI Pattern Analysis

struct SwiftUIReport: Codable {
    let analyzedAt: String
    var isSwiftUIProject: Bool
    var swiftUIFileCount: Int
    var uiKitFileCount: Int
    var mixedFiles: Int
    var views: [SwiftUIViewInfo]
    var stateManagement: StateManagementInfo
    var patterns: [String: Int]
    var issues: [SwiftUIIssue]
}

struct SwiftUIViewInfo: Codable {
    let name: String
    let file: String
    let line: Int?
    var stateProperties: Int
    var bindingProperties: Int
    var observedObjects: Int
    var environmentObjects: Int
    var bodyComplexity: Int  // rough line count of body
}

struct StateManagementInfo: Codable {
    var stateCount: Int
    var bindingCount: Int
    var observedObjectCount: Int
    var stateObjectCount: Int
    var environmentObjectCount: Int
    var environmentCount: Int
    var publishedCount: Int
    var observableCount: Int  // @Observable macro
}

struct SwiftUIIssue: Codable {
    let file: String
    let line: Int?
    let issue: IssueType
    let description: String
    
    enum IssueType: String, Codable {
        case heavyBody = "Heavy View Body"
        case missingStateObject = "Missing @StateObject"
        case observedInsteadOfStateObject = "@ObservedObject should be @StateObject"
        case tooManyStateProperties = "Too Many State Properties"
        case missingEnvironmentObject = "Possible Missing @EnvironmentObject"
    }
}

// MARK: - SwiftUI Visitor

final class SwiftUIVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var views: [SwiftUIViewInfo] = []
    private(set) var patterns: [String: Int] = [:]
    private(set) var issues: [SwiftUIIssue] = []
    private(set) var stateManagement = StateManagementInfo(
        stateCount: 0, bindingCount: 0, observedObjectCount: 0,
        stateObjectCount: 0, environmentObjectCount: 0,
        environmentCount: 0, publishedCount: 0, observableCount: 0
    )
    
    private(set) var hasSwiftUI = false
    private(set) var hasUIKit = false
    
    private var currentViewName: String?
    private var currentViewStateCount = 0
    private var currentViewBindingCount = 0
    private var currentViewObservedCount = 0
    private var currentViewEnvironmentCount = 0
    private var currentViewStartLine: Int?
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Detect imports
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let importName = node.path.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if importName == "SwiftUI" {
            hasSwiftUI = true
            patterns["import SwiftUI", default: 0] += 1
        }
        if importName == "UIKit" {
            hasUIKit = true
            patterns["import UIKit", default: 0] += 1
        }
        if importName == "Combine" {
            patterns["import Combine", default: 0] += 1
        }
        return .skipChildren
    }
    
    // Detect View conformance
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if let inheritance = node.inheritanceClause {
            let types = inheritance.inheritedTypes.map { 
                $0.type.description.trimmingCharacters(in: .whitespacesAndNewlines) 
            }
            
            if types.contains("View") {
                currentViewName = node.name.text
                currentViewStartLine = lineNumber(for: node.position)
                currentViewStateCount = 0
                currentViewBindingCount = 0
                currentViewObservedCount = 0
                currentViewEnvironmentCount = 0
                patterns["View", default: 0] += 1
            }
        }
        return .visitChildren
    }
    
    override func visitPost(_ node: StructDeclSyntax) {
        if let viewName = currentViewName {
            let endLine = lineNumber(for: node.endPosition) ?? 0
            let startLine = currentViewStartLine ?? 0
            
            views.append(SwiftUIViewInfo(
                name: viewName,
                file: filePath,
                line: currentViewStartLine,
                stateProperties: currentViewStateCount,
                bindingProperties: currentViewBindingCount,
                observedObjects: currentViewObservedCount,
                environmentObjects: currentViewEnvironmentCount,
                bodyComplexity: endLine - startLine
            ))
            
            // Check for issues
            if currentViewStateCount > 5 {
                issues.append(SwiftUIIssue(
                    file: filePath,
                    line: currentViewStartLine,
                    issue: .tooManyStateProperties,
                    description: "\(viewName) has \(currentViewStateCount) @State properties - consider extracting to ViewModel"
                ))
            }
            
            currentViewName = nil
        }
    }
    
    // Detect property wrappers
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let attrText = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if attrText.contains("@State") && !attrText.contains("@StateObject") {
            stateManagement.stateCount += 1
            currentViewStateCount += 1
            patterns["@State", default: 0] += 1
        }
        if attrText.contains("@Binding") {
            stateManagement.bindingCount += 1
            currentViewBindingCount += 1
            patterns["@Binding", default: 0] += 1
        }
        if attrText.contains("@ObservedObject") {
            stateManagement.observedObjectCount += 1
            currentViewObservedCount += 1
            patterns["@ObservedObject", default: 0] += 1
        }
        if attrText.contains("@StateObject") {
            stateManagement.stateObjectCount += 1
            patterns["@StateObject", default: 0] += 1
        }
        if attrText.contains("@EnvironmentObject") {
            stateManagement.environmentObjectCount += 1
            currentViewEnvironmentCount += 1
            patterns["@EnvironmentObject", default: 0] += 1
        }
        if attrText.contains("@Environment") && !attrText.contains("@EnvironmentObject") {
            stateManagement.environmentCount += 1
            patterns["@Environment", default: 0] += 1
        }
        if attrText.contains("@Published") {
            stateManagement.publishedCount += 1
            patterns["@Published", default: 0] += 1
        }
        if attrText.contains("@Observable") {
            stateManagement.observableCount += 1
            patterns["@Observable", default: 0] += 1
        }
        
        return .visitChildren
    }
    
    // Detect SwiftUI-specific types
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        
        let swiftUITypes = ["NavigationView", "NavigationStack", "List", "Form", 
                           "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack",
                           "ScrollView", "TabView", "Sheet", "Alert"]
        
        if swiftUITypes.contains(typeName) {
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

// MARK: - SwiftUI Analyzer

class SwiftUIAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> SwiftUIReport {
        var allViews: [SwiftUIViewInfo] = []
        var allPatterns: [String: Int] = [:]
        var allIssues: [SwiftUIIssue] = []
        var totalStateManagement = StateManagementInfo(
            stateCount: 0, bindingCount: 0, observedObjectCount: 0,
            stateObjectCount: 0, environmentObjectCount: 0,
            environmentCount: 0, publishedCount: 0, observableCount: 0
        )
        
        var swiftUIFiles = 0
        var uiKitFiles = 0
        var mixedFiles = 0
        
        for file in parsedFiles {
            let visitor = SwiftUIVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            // Count file types
            if visitor.hasSwiftUI && visitor.hasUIKit {
                mixedFiles += 1
            } else if visitor.hasSwiftUI {
                swiftUIFiles += 1
            } else if visitor.hasUIKit {
                uiKitFiles += 1
            }
            
            allViews.append(contentsOf: visitor.views)
            allIssues.append(contentsOf: visitor.issues)
            
            for (pattern, count) in visitor.patterns {
                allPatterns[pattern, default: 0] += count
            }
            
            // Aggregate state management
            totalStateManagement.stateCount += visitor.stateManagement.stateCount
            totalStateManagement.bindingCount += visitor.stateManagement.bindingCount
            totalStateManagement.observedObjectCount += visitor.stateManagement.observedObjectCount
            totalStateManagement.stateObjectCount += visitor.stateManagement.stateObjectCount
            totalStateManagement.environmentObjectCount += visitor.stateManagement.environmentObjectCount
            totalStateManagement.environmentCount += visitor.stateManagement.environmentCount
            totalStateManagement.publishedCount += visitor.stateManagement.publishedCount
            totalStateManagement.observableCount += visitor.stateManagement.observableCount
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return SwiftUIReport(
            analyzedAt: dateFormatter.string(from: Date()),
            isSwiftUIProject: swiftUIFiles > 10,
            swiftUIFileCount: swiftUIFiles,
            uiKitFileCount: uiKitFiles,
            mixedFiles: mixedFiles,
            views: allViews.sorted { $0.bodyComplexity > $1.bodyComplexity },
            stateManagement: totalStateManagement,
            patterns: allPatterns,
            issues: allIssues
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> SwiftUIReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
