import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Refactoring Analysis Report

struct RefactoringReport: Codable {
    let analyzedAt: String
    var godFunctions: [GodFunctionAnalysis]
    var extractionOpportunities: [ExtractionOpportunity]
    var totalComplexityReduction: Int
    var recommendations: [String]
}

struct GodFunctionAnalysis: Codable {
    let name: String
    let file: String
    let startLine: Int
    let endLine: Int
    let lineCount: Int
    let complexity: Int
    var logicalBlocks: [LogicalBlock]
    var sharedVariables: [SharedVariable]
    var extractableBlocks: [ExtractableBlock]
}

struct LogicalBlock: Codable {
    let name: String  // Inferred or from comment
    let startLine: Int
    let endLine: Int
    let lineCount: Int
    let complexity: Int
    let blockType: BlockType
    
    enum BlockType: String, Codable {
        case conditional = "if/else"
        case loop = "loop"
        case guardEarlyReturn = "guard"
        case codeSection = "section"  // Marked by // MARK or comment
        case assignment = "assignment"
        case functionCall = "call"
    }
}

struct SharedVariable: Codable {
    let name: String
    let declaredAtLine: Int
    let usedInBlocks: [String]  // Block names that use this variable
    let isMutated: Bool
}

struct ExtractableBlock: Codable {
    let suggestedName: String
    let startLine: Int
    let endLine: Int
    let lineCount: Int
    let complexity: Int
    let parameters: [String]  // Variables needed from outside
    let returns: String?  // What it would return
    let extractionDifficulty: Difficulty
    let reason: String
    
    // Enhanced context for AI-assisted refactoring
    var usedAnalyzers: [AnalyzerUsage]  // Analyzers called in this block
    var specialDependencies: [String]   // e.g., "typeMap from DependencyGraphAnalyzer"
    var codePreview: String?            // First few lines of the block
    var generatedSignature: String?     // Ready-to-use function signature
    var blockId: String = ""            // Stable identifier: "file:function#blockName"
    
    enum Difficulty: String, Codable {
        case easy = "easy"      // No shared state, clear boundaries
        case medium = "medium"  // Some parameters needed
        case hard = "hard"      // Shared mutable state, special dependencies
    }
    
    // Generate a copy-paste ready function signature
    static func generateSignature(name: String, params: [String], returnType: String?) -> String {
        let paramsStr = params.isEmpty ? "" : params.joined(separator: ", ")
        let retStr = returnType.map { " -> \($0)" } ?? ""
        return "func \(name)(\(paramsStr))\(retStr)"
    }
}

struct AnalyzerUsage: Codable {
    let analyzerType: String      // e.g., "CodeSmellAnalyzer"
    let methodCalled: String      // e.g., "analyze"
    let returnType: String?       // e.g., "CodeSmellReport"
    let signature: String?        // e.g., "analyze(files: [URL], relativeTo: URL)"
    let keyProperties: [String]?  // e.g., ["totalSmells", "smellsByType", "hotspotFiles"]
    
    // Standard analyzer signatures lookup
    static func standardSignature(for analyzer: String) -> (sig: String, props: [String])? {
        let lookup: [String: (String, [String])] = [
            "CodeSmellAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalSmells", "smellsByType", "hotspotFiles"]),
            "NetworkAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["endpoints", "totalEndpoints", "networkPatterns"]),
            "ReactiveAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalSubscriptions", "potentialLeaks", "framework"]),
            "ViewControllerAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["viewControllers", "issues", "heavyLifecycleMethods"]),
            "LocalizationAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["hardcodedStrings", "localizedStrings", "localizationCoverage"]),
            "AccessibilityAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalUIElements", "accessibilityCoverage", "issues"]),
            "ThreadSafetyAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalIssues", "concurrencyPatterns"]),
            "SwiftUIAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["views", "stateManagement", "swiftUIFileCount"]),
            "UIKitAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["viewControllers", "patterns", "modernizationScore"]),
            "CoreDataAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["entities", "patterns", "hasCoreData"]),
            "DocumentationAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalPublicSymbols", "documentedSymbols", "coveragePercentage"]),
            "RetainCycleAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["potentialCycles", "delegateIssues", "riskScore"]),
            "RefactoringAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["godFunctions", "extractionOpportunities"]),
            "APIAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["types", "globalFunctions", "totalPublicAPIs"]),
            "TechDebtAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalMarkers", "markersByType", "hotspotFiles"]),
            "FunctionMetricsAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalFunctions", "godFunctions", "averageComplexity"]),
            "AuthMigrationAnalyzer": ("analyze(files: [URL], relativeTo: URL)", ["totalAccesses", "accessesByProperty", "migrationPriority"]),
            "DelegateAnalyzer": ("analyze(files: [URL], relativeTo: URL, typeMap: TypeMap)", ["totalDelegateAssignments", "delegateProtocols", "potentialIssues"]),
            "UnusedCodeAnalyzer": ("analyze(files: [URL], relativeTo: URL, targetFiles: Set<String>?)", ["potentiallyUnusedTypes", "potentiallyUnusedFunctions"]),
            "TestCoverageAnalyzer": ("analyze(files: [URL], relativeTo: URL, targetAnalysis: TargetAnalysis?)", ["totalTestFiles", "coveragePercentage", "testTargets"]),
            "DependencyManagerAnalyzer": ("analyze(projectRoot: URL)", ["pods", "totalDependencies", "recommendations"]),
        ]
        return lookup[analyzer]
    }
}

struct ExtractionOpportunity: Codable {
    let file: String
    let functionName: String
    var suggestedExtractions: [ExtractableBlock]
    let estimatedComplexityReduction: Int
}

// MARK: - Function Structure Visitor

final class FunctionStructureVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    let sourceLines: [String]
    
    private(set) var godFunctions: [GodFunctionAnalysis] = []
    
    private var currentFunction: String?
    private var currentFunctionStart: Int?
    private var currentBlocks: [LogicalBlock] = []
    private var currentVariables: [String: (line: Int, mutated: Bool)] = [:]
    private var nestingDepth = 0
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        self.sourceLines = sourceText.components(separatedBy: "\n")
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let funcName = node.name.text
        let startLine = lineNumber(for: node.position) ?? 1
        let endLine = lineNumber(for: node.endPosition) ?? startLine
        let lineCount = endLine - startLine + 1
        
        // Only analyze large functions
        guard lineCount > 50 else { return .skipChildren }
        
        currentFunction = funcName
        currentFunctionStart = startLine
        currentBlocks = []
        currentVariables = [:]
        
        // Analyze the function body
        if let body = node.body {
            analyzeBody(body, functionName: funcName, startLine: startLine, endLine: endLine)
        }
        
        return .skipChildren
    }
    
    private func analyzeBody(_ body: CodeBlockSyntax, functionName: String, startLine: Int, endLine: Int) {
        let lineCount = endLine - startLine + 1
        var complexity = 1
        var blocks: [LogicalBlock] = []
        var variables: [SharedVariable] = []
        
        // Find MARK comments and major sections
        let markSections = findMarkSections(startLine: startLine, endLine: endLine)
        blocks.append(contentsOf: markSections)
        
        // Analyze statements for complexity and blocks
        for statement in body.statements {
            let stmtStart = lineNumber(for: statement.position) ?? startLine
            let stmtEnd = lineNumber(for: statement.endPosition) ?? stmtStart
            
            // Count complexity
            let stmtText = statement.description
            complexity += countComplexity(in: stmtText)
            
            // Identify if blocks
            if statement.item.is(IfExprSyntax.self) || stmtText.trimmedPrefix.hasPrefix("if ") {
                let ifLines = stmtEnd - stmtStart + 1
                if ifLines > 10 {
                    blocks.append(LogicalBlock(
                        name: "if block at line \(stmtStart)",
                        startLine: stmtStart,
                        endLine: stmtEnd,
                        lineCount: ifLines,
                        complexity: countComplexity(in: stmtText),
                        blockType: .conditional
                    ))
                }
            }
            
            // Identify variable declarations
            if let varDecl = statement.item.as(VariableDeclSyntax.self) {
                for binding in varDecl.bindings {
                    let varName = binding.pattern.description.trimmingCharacters(in: .whitespaces)
                    variables.append(SharedVariable(
                        name: varName,
                        declaredAtLine: stmtStart,
                        usedInBlocks: [], // Would need more analysis
                        isMutated: varDecl.bindingSpecifier.text == "var"
                    ))
                }
            }
        }
        
        // Generate extraction suggestions
        let extractableBlocks = generateExtractionSuggestions(
            blocks: blocks,
            markSections: markSections,
            startLine: startLine,
            endLine: endLine,
            containerFile: filePath,
            containerFunction: functionName
        )
        
        godFunctions.append(GodFunctionAnalysis(
            name: functionName,
            file: filePath,
            startLine: startLine,
            endLine: endLine,
            lineCount: lineCount,
            complexity: complexity,
            logicalBlocks: blocks.sorted { $0.startLine < $1.startLine },
            sharedVariables: variables,
            extractableBlocks: extractableBlocks
        ))
    }
    
    private func findMarkSections(startLine: Int, endLine: Int) -> [LogicalBlock] {
        var sections: [LogicalBlock] = []
        var currentSectionStart: Int? = nil
        var currentSectionName: String? = nil
        
        for lineIdx in (startLine - 1)..<min(endLine, sourceLines.count) {
            let line = sourceLines[lineIdx]
            
            // Look for // MARK:, // MARK: -, or significant comments
            if line.contains("// MARK:") || line.contains("// ---") || line.contains("// ===") {
                // Close previous section
                if let sectionStart = currentSectionStart, let name = currentSectionName {
                    sections.append(LogicalBlock(
                        name: name,
                        startLine: sectionStart,
                        endLine: lineIdx,
                        lineCount: lineIdx - sectionStart + 1,
                        complexity: 0, // Would need to calculate
                        blockType: .codeSection
                    ))
                }
                
                // Start new section
                currentSectionStart = lineIdx + 1
                currentSectionName = line
                    .replacingOccurrences(of: "// MARK:", with: "")
                    .replacingOccurrences(of: "// ---", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            
            // Look for mode-specific patterns (e.g., "if authMigration ||")
            if line.contains("if ") && line.contains("Mode ||") || line.contains("|| runAll") {
                // This is likely an analysis mode block
                if let modeMatch = line.range(of: #"if\s+(\w+Mode)"#, options: .regularExpression) {
                    let modeName = String(line[modeMatch]).replacingOccurrences(of: "if ", with: "")
                    
                    if let sectionStart = currentSectionStart, let name = currentSectionName {
                        sections.append(LogicalBlock(
                            name: name,
                            startLine: sectionStart,
                            endLine: lineIdx,
                            lineCount: lineIdx - sectionStart + 1,
                            complexity: 0,
                            blockType: .codeSection
                        ))
                    }
                    
                    currentSectionStart = lineIdx + 1
                    currentSectionName = modeName
                }
            }
        }
        
        // Close final section
        if let sectionStart = currentSectionStart, let name = currentSectionName {
            sections.append(LogicalBlock(
                name: name,
                startLine: sectionStart,
                endLine: endLine,
                lineCount: endLine - sectionStart + 1,
                complexity: 0,
                blockType: .codeSection
            ))
        }
        
        return sections
    }
    
    private func generateExtractionSuggestions(
        blocks: [LogicalBlock],
        markSections: [LogicalBlock],
        startLine: Int,
        endLine: Int,
        containerFile: String,
        containerFunction: String
    ) -> [ExtractableBlock] {
        var suggestions: [ExtractableBlock] = []
        
        // Look for repeated patterns in source
        // Pattern: "if <mode>Mode || runAll { ... if <mode>Mode && !runAll { return } }"
        var currentModeStart: Int? = nil
        var currentModeName: String? = nil
        
        for lineIdx in (startLine - 1)..<min(endLine, sourceLines.count) {
            let line = sourceLines[lineIdx]
            
            // Detect mode block start
            if line.contains("|| runAll {") {
                // Extract mode name
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("if ") {
                    let parts = trimmed.dropFirst(3).components(separatedBy: " ")
                    if let modeName = parts.first {
                        // Close previous block and analyze it
                        if let modeStart = currentModeStart, let name = currentModeName {
                            let blockEnd = lineIdx
                            let blockLines = getBlockLines(from: modeStart, to: blockEnd)
                            let (analyzers, deps, difficulty) = analyzeBlockContent(blockLines)
                            
                            let funcName = "run\(name.replacingOccurrences(of: "Mode", with: "").capitalized)Analysis"
                            let params = ["ctx: AnalysisContext", "isSpecificMode: Bool", "runAll: Bool"]
                            let lineCount = blockEnd - modeStart + 1
                            
                            // Skip small blocks (already extracted - typically < 15 lines)
                            guard lineCount > 15 else { continue }
                            
                            // More lines for larger blocks
                            let previewLines = lineCount > 50 ? 10 : (lineCount > 20 ? 5 : 3)
                            
                            // Create stable blockId: "file:function#suggestedName"
                            let blockId = "\(containerFile):\(containerFunction)#\(funcName)"
                            
                            suggestions.append(ExtractableBlock(
                                suggestedName: funcName,
                                startLine: modeStart,
                                endLine: blockEnd,
                                lineCount: lineCount,
                                complexity: 0,
                                parameters: params,
                                returns: "Bool",
                                extractionDifficulty: difficulty,
                                reason: deps.isEmpty ? "Standard analysis block" : "Has dependencies: \(deps.joined(separator: ", "))",
                                usedAnalyzers: analyzers,
                                specialDependencies: deps,
                                codePreview: blockLines.prefix(previewLines).joined(separator: "\n"),
                                generatedSignature: ExtractableBlock.generateSignature(name: funcName, params: params, returnType: "Bool"),
                                blockId: blockId
                            ))
                        }
                        
                        currentModeStart = lineIdx + 1
                        currentModeName = modeName
                    }
                }
            }
        }
        
        // Add final block
        if let modeStart = currentModeStart, let name = currentModeName {
            let blockLines = getBlockLines(from: modeStart, to: endLine)
            let (analyzers, deps, difficulty) = analyzeBlockContent(blockLines)
            
            let funcName = "run\(name.replacingOccurrences(of: "Mode", with: "").capitalized)Analysis"
            let params = ["ctx: AnalysisContext", "isSpecificMode: Bool", "runAll: Bool"]
            let lineCount = endLine - modeStart + 1
            
            // Skip small blocks (already extracted - typically < 15 lines)
            guard lineCount > 15 else { return suggestions }
            
            // More lines for larger blocks
            let previewLines = lineCount > 50 ? 10 : (lineCount > 20 ? 5 : 3)
            
            // Create stable blockId
            let blockId = "\(containerFile):\(containerFunction)#\(funcName)"
            
            suggestions.append(ExtractableBlock(
                suggestedName: funcName,
                startLine: modeStart,
                endLine: endLine,
                lineCount: lineCount,
                complexity: 0,
                parameters: params,
                returns: "Bool",
                extractionDifficulty: difficulty,
                reason: deps.isEmpty ? "Standard analysis block" : "Has dependencies: \(deps.joined(separator: ", "))",
                usedAnalyzers: analyzers,
                specialDependencies: deps,
                codePreview: blockLines.prefix(previewLines).joined(separator: "\n"),
                generatedSignature: ExtractableBlock.generateSignature(name: funcName, params: params, returnType: "Bool"),
                blockId: blockId
            ))
        }
        
        // Also check MARK sections as extraction candidates (general pattern)
        for section in markSections {
            let lineCount = section.lineCount
            
            // Only suggest sections > 20 lines
            guard lineCount > 20 else { continue }
            
            // Generate a function name from the MARK name
            let cleanName = section.name
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .map { $0.capitalized }
                .joined()
            let funcName = cleanName.isEmpty ? "extractedSection\(section.startLine)" : "handle\(cleanName)"
            
            // Check if we already have a suggestion for this range
            let alreadySuggested = suggestions.contains { s in
                abs(s.startLine - section.startLine) < 5 && abs(s.endLine - section.endLine) < 5
            }
            guard !alreadySuggested else { continue }
            
            let blockLines = getBlockLines(from: section.startLine, to: section.endLine)
            let previewLines = lineCount > 50 ? 10 : (lineCount > 20 ? 5 : 3)
            let blockId = "\(containerFile):\(containerFunction)#\(funcName)"
            
            suggestions.append(ExtractableBlock(
                suggestedName: funcName,
                startLine: section.startLine,
                endLine: section.endLine,
                lineCount: lineCount,
                complexity: 0,
                parameters: [],
                returns: nil,
                extractionDifficulty: .medium,
                reason: "MARK section '\(section.name)' is \(lineCount) lines",
                usedAnalyzers: [],
                specialDependencies: [],
                codePreview: blockLines.prefix(previewLines).joined(separator: "\n"),
                generatedSignature: "func \(funcName)()",
                blockId: blockId
            ))
        }
        
        return suggestions
    }
    
    private func getBlockLines(from start: Int, to end: Int) -> [String] {
        let startIdx = max(0, start - 1)
        let endIdx = min(sourceLines.count, end)
        return Array(sourceLines[startIdx..<endIdx])
    }
    
    private func analyzeBlockContent(_ lines: [String]) -> (analyzers: [AnalyzerUsage], dependencies: [String], difficulty: ExtractableBlock.Difficulty) {
        var analyzers: [AnalyzerUsage] = []
        var dependencies: [String] = []
        var difficulty: ExtractableBlock.Difficulty = .easy
        
        let content = lines.joined(separator: "\n")
        
        // Detect analyzer instantiations: "let analyzer = SomeAnalyzer()"
        let analyzerPattern = #"let\s+(\w+)\s*=\s*(\w+Analyzer)\(\)"#
        if let regex = try? NSRegularExpression(pattern: analyzerPattern) {
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, range: range)
            for match in matches {
                if let typeRange = Range(match.range(at: 2), in: content) {
                    let analyzerType = String(content[typeRange])
                    
                    // Detect the analyze call and return type
                    var returnType: String? = nil
                    let reportPattern = "let\\s+(\\w+)\\s*=\\s*\\w+\\.analyze"
                    if let reportRegex = try? NSRegularExpression(pattern: reportPattern),
                       let reportMatch = reportRegex.firstMatch(in: content, range: range),
                       let varRange = Range(reportMatch.range(at: 1), in: content) {
                        let varName = String(content[varRange])
                        // Infer return type from variable name
                        if varName.hasSuffix("Report") {
                            returnType = varName.replacingOccurrences(of: "Report", with: "") + "Report"
                        } else {
                            returnType = analyzerType.replacingOccurrences(of: "Analyzer", with: "Report")
                        }
                    }
                    
                    // Look up full signature and key properties
                    let stdInfo = AnalyzerUsage.standardSignature(for: analyzerType)
                    
                    analyzers.append(AnalyzerUsage(
                        analyzerType: analyzerType,
                        methodCalled: "analyze",
                        returnType: returnType ?? analyzerType.replacingOccurrences(of: "Analyzer", with: "Report"),
                        signature: stdInfo?.sig,
                        keyProperties: stdInfo?.props
                    ))
                }
            }
        }
        
        // Detect special dependencies
        if content.contains("typeMap") || content.contains("analyzeTypes") {
            dependencies.append("typeMap from DependencyGraphAnalyzer.analyzeTypes()")
            difficulty = .hard
        }
        
        if content.contains("targetFiles") || content.contains("targetAnalysis") {
            dependencies.append("targetFiles from targetAnalysis")
            difficulty = .hard
        }
        
        if content.contains("parentURL") || content.contains("deletingLastPathComponent") {
            dependencies.append("parentURL (analyzes parent directory)")
            difficulty = .hard
        }
        
        if content.contains("for (index, fileURL)") || content.contains("for fileURL in") {
            dependencies.append("iterates over files directly")
            difficulty = .hard
        }
        
        // If we found analyzers but no special deps, it's medium difficulty
        if !analyzers.isEmpty && dependencies.isEmpty {
            difficulty = .medium
        }
        
        return (analyzers, dependencies, difficulty)
    }
    
    private func countComplexity(in text: String) -> Int {
        var complexity = 0
        let keywords = ["if ", "else ", "for ", "while ", "switch ", "case ", "guard ", "catch ", "&&", "||", "?:"]
        for keyword in keywords {
            complexity += text.components(separatedBy: keyword).count - 1
        }
        return complexity
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

extension String {
    var trimmedPrefix: String {
        return self.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Refactoring Analyzer

class RefactoringAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> RefactoringReport {
        var allGodFunctions: [GodFunctionAnalysis] = []
        var allExtractions: [ExtractionOpportunity] = []
        
        for file in parsedFiles {
            let visitor = FunctionStructureVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            allGodFunctions.append(contentsOf: visitor.godFunctions)
            
            // Create extraction opportunities from god functions
            for godFunc in visitor.godFunctions {
                if !godFunc.extractableBlocks.isEmpty {
                    let estimatedReduction = godFunc.extractableBlocks.reduce(0) { $0 + $1.lineCount }
                    allExtractions.append(ExtractionOpportunity(
                        file: file.relativePath,
                        functionName: godFunc.name,
                        suggestedExtractions: godFunc.extractableBlocks,
                        estimatedComplexityReduction: estimatedReduction / 10
                    ))
                }
            }
        }
        
        // Sort by impact
        allGodFunctions.sort { $0.lineCount * $0.complexity > $1.lineCount * $1.complexity }
        
        // Generate recommendations
        var recommendations: [String] = []
        if let worst = allGodFunctions.first {
            recommendations.append("Priority 1: Refactor \(worst.file):\(worst.name) - \(worst.lineCount) lines, complexity \(worst.complexity)")
            if !worst.extractableBlocks.isEmpty {
                recommendations.append("  → Can extract \(worst.extractableBlocks.count) functions")
                for extract in worst.extractableBlocks.prefix(5) {
                    recommendations.append("    - \(extract.suggestedName)() [lines \(extract.startLine)-\(extract.endLine)]")
                }
            }
        }
        
        let totalReduction = allExtractions.reduce(0) { $0 + $1.estimatedComplexityReduction }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return RefactoringReport(
            analyzedAt: dateFormatter.string(from: Date()),
            godFunctions: allGodFunctions,
            extractionOpportunities: allExtractions,
            totalComplexityReduction: totalReduction,
            recommendations: recommendations
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> RefactoringReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
