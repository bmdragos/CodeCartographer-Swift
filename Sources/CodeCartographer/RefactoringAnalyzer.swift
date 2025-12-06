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
    
    enum Difficulty: String, Codable {
        case easy = "easy"      // No shared state, clear boundaries
        case medium = "medium"  // Some parameters needed
        case hard = "hard"      // Shared mutable state
    }
}

struct ExtractionOpportunity: Codable {
    let file: String
    let functionName: String
    let suggestedExtractions: [ExtractableBlock]
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
            endLine: endLine
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
        endLine: Int
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
                        // Close previous block
                        if let modeStart = currentModeStart, let name = currentModeName {
                            let blockEnd = lineIdx
                            suggestions.append(ExtractableBlock(
                                suggestedName: "run\(name.replacingOccurrences(of: "Mode", with: "").capitalized)Analysis",
                                startLine: modeStart,
                                endLine: blockEnd,
                                lineCount: blockEnd - modeStart + 1,
                                complexity: 0,
                                parameters: ["files: [URL]", "root: URL", "options: CLIOptions"],
                                returns: nil,
                                extractionDifficulty: .medium,
                                reason: "Analysis mode block - follows consistent pattern"
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
            suggestions.append(ExtractableBlock(
                suggestedName: "run\(name.replacingOccurrences(of: "Mode", with: "").capitalized)Analysis",
                startLine: modeStart,
                endLine: endLine,
                lineCount: endLine - modeStart + 1,
                complexity: 0,
                parameters: ["files: [URL]", "root: URL", "options: CLIOptions"],
                returns: nil,
                extractionDifficulty: .medium,
                reason: "Analysis mode block - follows consistent pattern"
            ))
        }
        
        return suggestions
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

class RefactoringAnalyzer {
    
    func analyze(files: [URL], relativeTo root: URL) -> RefactoringReport {
        var allGodFunctions: [GodFunctionAnalysis] = []
        var allExtractions: [ExtractionOpportunity] = []
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = FunctionStructureVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            allGodFunctions.append(contentsOf: visitor.godFunctions)
            
            // Create extraction opportunities from god functions
            for godFunc in visitor.godFunctions {
                if !godFunc.extractableBlocks.isEmpty {
                    let estimatedReduction = godFunc.extractableBlocks.reduce(0) { $0 + $1.lineCount }
                    allExtractions.append(ExtractionOpportunity(
                        file: relativePath,
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
}
