import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Unused Code Analysis

struct UnusedCodeReport: Codable {
    let analyzedAt: String
    var potentiallyUnusedTypes: [UnusedType]
    var potentiallyUnusedFunctions: [UnusedFunction]
    var unusedImports: [UnusedImport]
    var summary: UnusedCodeSummary
}

struct UnusedType: Codable {
    let name: String
    let kind: String  // class, struct, enum
    let file: String
    let line: Int?
    let reason: String
}

struct UnusedFunction: Codable {
    let name: String
    let file: String
    let line: Int?
    let visibility: String  // private, internal, public
    let reason: String
}

struct UnusedImport: Codable {
    let module: String
    let file: String
    let usageCount: Int  // 0 means potentially unused
}

struct UnusedCodeSummary: Codable {
    var totalUnusedTypes: Int
    var totalUnusedFunctions: Int
    var totalUnusedImports: Int
    var estimatedDeadLines: Int
}

// MARK: - Symbol Usage Tracker

final class SymbolUsageVisitor: SyntaxVisitor {
    let filePath: String
    
    // Definitions in this file
    private(set) var definedTypes: [(String, String, Int?)] = []  // (name, kind, line)
    private(set) var definedFunctions: [(String, String, Int?)] = []  // (name, visibility, line)
    private(set) var imports: [String] = []
    
    // References (symbols used)
    private(set) var referencedSymbols: Set<String> = []
    
    init(filePath: String) {
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }
    
    // Track imports
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let moduleName = node.path.first?.name.text {
            imports.append(moduleName)
        }
        return .skipChildren
    }
    
    // Track type definitions
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.append((node.name.text, "class", nil))
        return .visitChildren
    }
    
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.append((node.name.text, "struct", nil))
        return .visitChildren
    }
    
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        definedTypes.append((node.name.text, "enum", nil))
        return .visitChildren
    }
    
    // Track function definitions
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let visibility = getVisibility(from: node.modifiers)
        definedFunctions.append((node.name.text, visibility, nil))
        return .visitChildren
    }
    
    // Track symbol references
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        referencedSymbols.insert(node.baseName.text)
        return .visitChildren
    }
    
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        referencedSymbols.insert(node.name.text)
        return .visitChildren
    }
    
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        referencedSymbols.insert(node.declName.baseName.text)
        if let base = node.base?.description.trimmingCharacters(in: .whitespacesAndNewlines) {
            referencedSymbols.insert(base)
        }
        return .visitChildren
    }
    
    private func getVisibility(from modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            let name = modifier.name.text
            if ["private", "fileprivate", "internal", "public", "open"].contains(name) {
                return name
            }
        }
        return "internal"
    }
}

// MARK: - Unused Code Analyzer

class UnusedCodeAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile], targetFiles: Set<String>?) -> UnusedCodeReport {
        var allDefinedTypes: [(String, String, String, Int?)] = []  // (name, kind, file, line)
        var allDefinedFunctions: [(String, String, String, Int?)] = []  // (name, visibility, file, line)
        var allReferencedSymbols: Set<String> = []
        var fileImports: [String: [String]] = [:]
        var moduleUsage: [String: Int] = [:]
        
        // First pass: collect all definitions and references
        for file in parsedFiles {
            let visitor = SymbolUsageVisitor(filePath: file.relativePath)
            visitor.walk(file.ast)
            
            for (name, kind, line) in visitor.definedTypes {
                allDefinedTypes.append((name, kind, file.relativePath, line))
            }
            
            for (name, vis, line) in visitor.definedFunctions {
                allDefinedFunctions.append((name, vis, file.relativePath, line))
            }
            
            allReferencedSymbols.formUnion(visitor.referencedSymbols)
            fileImports[file.relativePath] = visitor.imports
            
            // Track module usage
            for imp in visitor.imports {
                moduleUsage[imp, default: 0] += 1
            }
        }
        
        // Find potentially unused types
        var unusedTypes: [UnusedType] = []
        for (name, kind, file, line) in allDefinedTypes {
            // Skip common patterns that are likely used via reflection/storyboards
            if name.hasSuffix("ViewController") || name.hasSuffix("Cell") || 
               name.hasSuffix("View") || name.hasSuffix("Delegate") {
                continue
            }
            
            // Check if type is referenced anywhere
            if !allReferencedSymbols.contains(name) {
                // Check if file is in target (if target info provided)
                let reason: String
                if let targetFiles = targetFiles, !targetFiles.contains(file.components(separatedBy: "/").last ?? "") {
                    reason = "Not in any build target and not referenced"
                } else {
                    reason = "No references found in codebase"
                }
                
                unusedTypes.append(UnusedType(
                    name: name,
                    kind: kind,
                    file: file,
                    line: line,
                    reason: reason
                ))
            }
        }
        
        // Find potentially unused private/fileprivate functions
        var unusedFunctions: [UnusedFunction] = []
        for (name, visibility, file, line) in allDefinedFunctions {
            // Only flag private/fileprivate functions
            if visibility == "private" || visibility == "fileprivate" {
                if !allReferencedSymbols.contains(name) {
                    unusedFunctions.append(UnusedFunction(
                        name: name,
                        file: file,
                        line: line,
                        visibility: visibility,
                        reason: "Private function with no references in file"
                    ))
                }
            }
        }
        
        // Find unused imports (imports with low usage)
        var unusedImports: [UnusedImport] = []
        // This is a heuristic - we can't perfectly detect unused imports without type resolution
        
        let dateFormatter = ISO8601DateFormatter()
        
        return UnusedCodeReport(
            analyzedAt: dateFormatter.string(from: Date()),
            potentiallyUnusedTypes: unusedTypes.sorted { $0.file < $1.file },
            potentiallyUnusedFunctions: unusedFunctions.sorted { $0.file < $1.file },
            unusedImports: unusedImports,
            summary: UnusedCodeSummary(
                totalUnusedTypes: unusedTypes.count,
                totalUnusedFunctions: unusedFunctions.count,
                totalUnusedImports: unusedImports.count,
                estimatedDeadLines: unusedTypes.count * 50 + unusedFunctions.count * 10  // rough estimate
            )
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL, targetFiles: Set<String>?) -> UnusedCodeReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles, targetFiles: targetFiles)
    }
}
