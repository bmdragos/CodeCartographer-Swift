import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Delegate Wiring Analysis

struct DelegateWiringReport: Codable {
    let analyzedAt: String
    var totalDelegateAssignments: Int
    var delegateProtocols: [DelegateProtocolInfo]
    var wiringsByFile: [String: [DelegateWiring]]
    var potentialIssues: [DelegateIssue]
}

struct DelegateProtocolInfo: Codable {
    let protocolName: String
    var implementers: [String]  // types that conform
    var assignmentCount: Int    // how many times delegate is set
}

struct DelegateWiring: Codable {
    let file: String
    let line: Int?
    let delegateProperty: String  // e.g., "tableView.delegate"
    let assignedTo: String        // e.g., "self"
    let context: String?          // function where assignment happens
}

struct DelegateIssue: Codable {
    let file: String
    let line: Int?
    let issue: IssueType
    let description: String
    
    enum IssueType: String, Codable {
        case strongDelegateReference  // delegate not weak
        case delegateSetInInit        // might cause issues
        case missingDelegateConformance
    }
}

// MARK: - Delegate Visitor

final class DelegateWiringVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var wirings: [DelegateWiring] = []
    private(set) var delegateProperties: [(String, Bool)] = []  // (name, isWeak)
    private var currentContext: String?
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }
    
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = "init"
        return .visitChildren
    }
    
    override func visitPost(_ node: InitializerDeclSyntax) {
        currentContext = nil
    }
    
    // Detect delegate property declarations
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let declText = node.description.lowercased()
        
        if declText.contains("delegate") || declText.contains("datasource") {
            let isWeak = node.modifiers.contains { $0.name.text == "weak" }
            
            for binding in node.bindings {
                if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                    delegateProperties.append((name, isWeak))
                }
            }
        }
        
        return .visitChildren
    }
    
    // Detect delegate assignments: foo.delegate = self
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let opText = node.operator.description.trimmingCharacters(in: .whitespaces)
        
        if opText == "=" {
            let leftSide = node.leftOperand.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let rightSide = node.rightOperand.description.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if assigning to a delegate property
            if leftSide.lowercased().contains("delegate") || leftSide.lowercased().contains("datasource") {
                wirings.append(DelegateWiring(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    delegateProperty: leftSide,
                    assignedTo: rightSide,
                    context: currentContext
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

// MARK: - Delegate Analyzer

class DelegateAnalyzer {
    
    func analyze(files: [URL], relativeTo root: URL, typeMap: TypeMap) -> DelegateWiringReport {
        var allWirings: [DelegateWiring] = []
        var wiringsByFile: [String: [DelegateWiring]] = [:]
        var issues: [DelegateIssue] = []
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = DelegateWiringVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            allWirings.append(contentsOf: visitor.wirings)
            if !visitor.wirings.isEmpty {
                wiringsByFile[relativePath] = visitor.wirings
            }
            
            // Check for non-weak delegate properties
            for (propName, isWeak) in visitor.delegateProperties {
                if !isWeak {
                    issues.append(DelegateIssue(
                        file: relativePath,
                        line: nil,
                        issue: .strongDelegateReference,
                        description: "Property '\(propName)' should be weak to avoid retain cycles"
                    ))
                }
            }
            
            // Check for delegate set in init
            for wiring in visitor.wirings {
                if wiring.context == "init" {
                    issues.append(DelegateIssue(
                        file: relativePath,
                        line: wiring.line,
                        issue: .delegateSetInInit,
                        description: "Delegate '\(wiring.delegateProperty)' set in init - may cause issues if delegate isn't ready"
                    ))
                }
            }
        }
        
        // Build delegate protocol info from type map
        var delegateProtocols: [DelegateProtocolInfo] = []
        for (protoName, conformers) in typeMap.protocolConformances {
            if protoName.contains("Delegate") || protoName.contains("DataSource") {
                let assignmentCount = allWirings.filter { 
                    $0.delegateProperty.lowercased().contains(protoName.lowercased().replacingOccurrences(of: "delegate", with: ""))
                }.count
                
                delegateProtocols.append(DelegateProtocolInfo(
                    protocolName: protoName,
                    implementers: conformers,
                    assignmentCount: assignmentCount
                ))
            }
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return DelegateWiringReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalDelegateAssignments: allWirings.count,
            delegateProtocols: delegateProtocols.sorted { $0.implementers.count > $1.implementers.count },
            wiringsByFile: wiringsByFile,
            potentialIssues: issues
        )
    }
}
