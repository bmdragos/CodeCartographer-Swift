//
//  MethodCallAnalyzer.swift
//  CodeCartographer
//
//  Finds method calls matching a pattern (e.g., "*.forgotPassword", "pool.*")
//

import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Method Call

struct MethodCall: Codable {
    let file: String
    let line: Int
    let methodName: String
    let receiver: String?  // The object the method is called on
    let fullExpression: String
    let context: String?  // Function containing this call
}

// MARK: - Method Call Report

struct MethodCallReport: Codable {
    let pattern: String
    let totalCalls: Int
    let callsByFile: [String: [MethodCall]]
    let callsByMethod: [String: Int]
    let files: [String]
}

// MARK: - Method Call Visitor

final class MethodCallVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    let pattern: String
    private let receiverPattern: String?  // e.g., "pool" from "pool.*"
    private let methodPattern: String?    // e.g., "forgotPassword" from "*.forgotPassword"
    
    private(set) var calls: [MethodCall] = []
    private var currentContext: String?
    
    init(filePath: String, sourceText: String, pattern: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        self.pattern = pattern
        
        // Parse pattern: "receiver.method" or "*.method" or "receiver.*"
        let parts = pattern.split(separator: ".", maxSplits: 1)
        if parts.count == 2 {
            let receiver = String(parts[0])
            let method = String(parts[1])
            self.receiverPattern = receiver == "*" ? nil : receiver
            self.methodPattern = method == "*" ? nil : method
        } else {
            // Single word - treat as method name
            self.receiverPattern = nil
            self.methodPattern = pattern
        }
        
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }
    
    // Detect function calls: receiver.method() or just method()
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let fullExpr = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Extract receiver and method name from the callee
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let methodName = memberAccess.declName.baseName.text
            let receiver = memberAccess.base?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if matchesPattern(receiver: receiver, method: methodName) {
                let call = MethodCall(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    methodName: methodName,
                    receiver: receiver.isEmpty ? nil : receiver,
                    fullExpression: String(fullExpr.prefix(150)),
                    context: currentContext
                )
                calls.append(call)
            }
        } else if let identifier = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            // Direct function call without receiver
            let methodName = identifier.baseName.text
            
            if matchesPattern(receiver: nil, method: methodName) {
                let call = MethodCall(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    methodName: methodName,
                    receiver: nil,
                    fullExpression: String(fullExpr.prefix(150)),
                    context: currentContext
                )
                calls.append(call)
            }
        }
        
        return .visitChildren
    }
    
    private func matchesPattern(receiver: String?, method: String) -> Bool {
        // Check method pattern
        if let methodPattern = methodPattern {
            if !method.contains(methodPattern) && method != methodPattern {
                return false
            }
        }
        
        // Check receiver pattern
        if let receiverPattern = receiverPattern {
            guard let receiver = receiver else { return false }
            if !receiver.contains(receiverPattern) && receiver != receiverPattern {
                return false
            }
        }
        
        return true
    }
    
    private func lineNumber(for position: AbsolutePosition) -> Int {
        let prefix = sourceText.prefix(position.utf8Offset)
        return prefix.filter { $0 == "\n" }.count + 1
    }
}

// MARK: - Method Call Analyzer

class MethodCallAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile], pattern: String) -> MethodCallReport {
        var allCalls: [MethodCall] = []
        
        for file in parsedFiles {
            let visitor = MethodCallVisitor(filePath: file.relativePath, sourceText: file.sourceText, pattern: pattern)
            visitor.walk(file.ast)
            
            allCalls.append(contentsOf: visitor.calls)
        }
        
        // Group by file
        let callsByFile = Dictionary(grouping: allCalls, by: { $0.file })
        
        // Count by method name
        var callsByMethod: [String: Int] = [:]
        for call in allCalls {
            callsByMethod[call.methodName, default: 0] += 1
        }
        
        // Unique files
        let files = Array(Set(allCalls.map { $0.file })).sorted()
        
        return MethodCallReport(
            pattern: pattern,
            totalCalls: allCalls.count,
            callsByFile: callsByFile,
            callsByMethod: callsByMethod.sorted { $0.value > $1.value }.reduce(into: [:]) { $0[$1.key] = $1.value },
            files: files
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL, pattern: String) -> MethodCallReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles, pattern: pattern)
    }
}
