import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Auto-Fix Generator

/// Generates code fixes for detected code smells
final class AutoFixGenerator {

    // MARK: - Types

    struct FixSuggestion: Codable {
        let smellType: String
        let file: String
        let line: Int
        let original: String
        let fixed: String
        let explanation: String
        let confidence: Confidence

        enum Confidence: String, Codable {
            case high = "high"         // Safe to apply automatically
            case medium = "medium"     // Review recommended
            case low = "low"           // Manual review required
        }
    }

    struct FixResult: Codable {
        let smell: SmellInfo
        let suggestion: FixSuggestion?
        let canAutoFix: Bool
        let reason: String?
    }

    struct SmellInfo: Codable {
        let type: String
        let file: String
        let line: Int?
        let code: String
    }

    // MARK: - Properties

    private let projectRoot: URL

    // MARK: - Initialization

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    // MARK: - Public API

    /// Generate a fix suggestion for a code smell
    func suggestFix(for smell: CodeSmell) -> FixResult {
        let smellInfo = SmellInfo(
            type: smell.type.rawValue,
            file: smell.file,
            line: smell.line,
            code: smell.code
        )

        guard let line = smell.line else {
            return FixResult(
                smell: smellInfo,
                suggestion: nil,
                canAutoFix: false,
                reason: "No line number available"
            )
        }

        // Read the source file
        let fileURL = projectRoot.appendingPathComponent(smell.file)
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return FixResult(
                smell: smellInfo,
                suggestion: nil,
                canAutoFix: false,
                reason: "Could not read source file"
            )
        }

        let lines = source.components(separatedBy: "\n")
        guard line > 0 && line <= lines.count else {
            return FixResult(
                smell: smellInfo,
                suggestion: nil,
                canAutoFix: false,
                reason: "Line number out of range"
            )
        }

        let originalLine = lines[line - 1]

        // Generate fix based on smell type
        switch smell.type {
        case .forceUnwrap:
            return generateForceUnwrapFix(smell: smellInfo, originalLine: originalLine, line: line)
        case .forceCast:
            return generateForceCastFix(smell: smellInfo, originalLine: originalLine, line: line)
        case .forceTry:
            return generateForceTryFix(smell: smellInfo, originalLine: originalLine, line: line)
        case .emptycatch:
            return generateEmptyCatchFix(smell: smellInfo, originalLine: originalLine, line: line)
        case .implicitlyUnwrapped:
            return generateIUOFix(smell: smellInfo, originalLine: originalLine, line: line)
        default:
            return FixResult(
                smell: smellInfo,
                suggestion: nil,
                canAutoFix: false,
                reason: "No auto-fix available for \(smell.type.rawValue)"
            )
        }
    }

    // MARK: - Fix Generators

    private func generateForceUnwrapFix(smell: SmellInfo, originalLine: String, line: Int) -> FixResult {
        // Pattern: let/var name = expression!
        // Fix: guard let name = expression else { return }

        let trimmed = originalLine.trimmingCharacters(in: .whitespaces)

        // Try to parse the assignment pattern
        if let match = extractForceUnwrapAssignment(trimmed) {
            let indent = String(originalLine.prefix(while: { $0 == " " || $0 == "\t" }))
            let fixed = "\(indent)guard let \(match.name) = \(match.expression) else { return }"

            return FixResult(
                smell: smell,
                suggestion: FixSuggestion(
                    smellType: smell.type,
                    file: smell.file,
                    line: line,
                    original: originalLine,
                    fixed: fixed,
                    explanation: "Replace force unwrap with guard let. Adjust the else clause as needed (return, throw, continue, etc.)",
                    confidence: .medium
                ),
                canAutoFix: true,
                reason: nil
            )
        }

        // Fallback: suggest nil coalescing if it's a simple expression
        if trimmed.contains("!") && !trimmed.contains("!=") {
            let fixed = originalLine.replacingOccurrences(of: "!", with: " ?? <#default#>")
            return FixResult(
                smell: smell,
                suggestion: FixSuggestion(
                    smellType: smell.type,
                    file: smell.file,
                    line: line,
                    original: originalLine,
                    fixed: fixed,
                    explanation: "Replace force unwrap with nil coalescing. Provide an appropriate default value.",
                    confidence: .low
                ),
                canAutoFix: true,
                reason: nil
            )
        }

        return FixResult(
            smell: smell,
            suggestion: nil,
            canAutoFix: false,
            reason: "Could not parse force unwrap pattern"
        )
    }

    private func generateForceCastFix(smell: SmellInfo, originalLine: String, line: Int) -> FixResult {
        // Pattern: expression as! Type
        // Fix: expression as? Type (with optional binding)

        let trimmed = originalLine.trimmingCharacters(in: .whitespaces)

        if let match = extractForceCastAssignment(trimmed) {
            let indent = String(originalLine.prefix(while: { $0 == " " || $0 == "\t" }))
            let fixed = "\(indent)guard let \(match.name) = \(match.expression) as? \(match.targetType) else { return }"

            return FixResult(
                smell: smell,
                suggestion: FixSuggestion(
                    smellType: smell.type,
                    file: smell.file,
                    line: line,
                    original: originalLine,
                    fixed: fixed,
                    explanation: "Replace force cast with conditional cast and guard. Adjust the else clause as needed.",
                    confidence: .medium
                ),
                canAutoFix: true,
                reason: nil
            )
        }

        // Simple replacement fallback
        if trimmed.contains(" as! ") {
            let fixed = originalLine.replacingOccurrences(of: " as! ", with: " as? ")
            return FixResult(
                smell: smell,
                suggestion: FixSuggestion(
                    smellType: smell.type,
                    file: smell.file,
                    line: line,
                    original: originalLine,
                    fixed: fixed,
                    explanation: "Replace force cast with conditional cast. Handle the optional result appropriately.",
                    confidence: .low
                ),
                canAutoFix: true,
                reason: nil
            )
        }

        return FixResult(
            smell: smell,
            suggestion: nil,
            canAutoFix: false,
            reason: "Could not parse force cast pattern"
        )
    }

    private func generateForceTryFix(smell: SmellInfo, originalLine: String, line: Int) -> FixResult {
        // Pattern: try! expression
        // Fix: do { try expression } catch { handle }

        let trimmed = originalLine.trimmingCharacters(in: .whitespaces)
        let indent = String(originalLine.prefix(while: { $0 == " " || $0 == "\t" }))

        if trimmed.contains("try!") {
            // Check if it's an assignment
            if let match = extractForceTryAssignment(trimmed) {
                let fixed = """
\(indent)do {
\(indent)    let \(match.name) = try \(match.expression)
\(indent)} catch {
\(indent)    // Handle error
\(indent)    return
\(indent)}
"""
                return FixResult(
                    smell: smell,
                    suggestion: FixSuggestion(
                        smellType: smell.type,
                        file: smell.file,
                        line: line,
                        original: originalLine,
                        fixed: fixed,
                        explanation: "Replace try! with do-catch block. Implement proper error handling.",
                        confidence: .medium
                    ),
                    canAutoFix: true,
                    reason: nil
                )
            }

            // Simple replacement
            let fixed = originalLine.replacingOccurrences(of: "try!", with: "try?")
            return FixResult(
                smell: smell,
                suggestion: FixSuggestion(
                    smellType: smell.type,
                    file: smell.file,
                    line: line,
                    original: originalLine,
                    fixed: fixed,
                    explanation: "Replace try! with try? Handle the optional result or use do-catch for proper error handling.",
                    confidence: .low
                ),
                canAutoFix: true,
                reason: nil
            )
        }

        return FixResult(
            smell: smell,
            suggestion: nil,
            canAutoFix: false,
            reason: "Could not parse force try pattern"
        )
    }

    private func generateEmptyCatchFix(smell: SmellInfo, originalLine: String, line: Int) -> FixResult {
        let indent = String(originalLine.prefix(while: { $0 == " " || $0 == "\t" }))

        let fixed = "\(indent)} catch {\n\(indent)    // TODO: Handle error appropriately\n\(indent)    print(\"Error: \\(error)\")\n\(indent)}"

        return FixResult(
            smell: smell,
            suggestion: FixSuggestion(
                smellType: smell.type,
                file: smell.file,
                line: line,
                original: originalLine,
                fixed: fixed,
                explanation: "Add error handling to the catch block. At minimum, log the error.",
                confidence: .medium
            ),
            canAutoFix: true,
            reason: nil
        )
    }

    private func generateIUOFix(smell: SmellInfo, originalLine: String, line: Int) -> FixResult {
        // Pattern: var/let name: Type!
        // Fix: var/let name: Type?

        if originalLine.contains("!") && !originalLine.contains("!=") {
            let fixed = originalLine.replacingOccurrences(of: "!", with: "?")
            return FixResult(
                smell: smell,
                suggestion: FixSuggestion(
                    smellType: smell.type,
                    file: smell.file,
                    line: line,
                    original: originalLine,
                    fixed: fixed,
                    explanation: "Replace implicitly unwrapped optional with regular optional. Update usage sites to handle nil.",
                    confidence: .medium
                ),
                canAutoFix: true,
                reason: nil
            )
        }

        return FixResult(
            smell: smell,
            suggestion: nil,
            canAutoFix: false,
            reason: "Could not parse implicitly unwrapped optional"
        )
    }

    // MARK: - Pattern Extraction

    private struct ForceUnwrapMatch {
        let name: String
        let expression: String
    }

    private func extractForceUnwrapAssignment(_ line: String) -> ForceUnwrapMatch? {
        // Match: let/var name = expression!
        let pattern = #"(let|var)\s+(\w+)\s*=\s*(.+)!"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let nameRange = Range(match.range(at: 2), in: line),
              let exprRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        return ForceUnwrapMatch(
            name: String(line[nameRange]),
            expression: String(line[exprRange]).trimmingCharacters(in: .whitespaces)
        )
    }

    private struct ForceCastMatch {
        let name: String
        let expression: String
        let targetType: String
    }

    private func extractForceCastAssignment(_ line: String) -> ForceCastMatch? {
        // Match: let/var name = expression as! Type
        let pattern = #"(let|var)\s+(\w+)\s*=\s*(.+)\s+as!\s+(\w+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let nameRange = Range(match.range(at: 2), in: line),
              let exprRange = Range(match.range(at: 3), in: line),
              let typeRange = Range(match.range(at: 4), in: line) else {
            return nil
        }

        return ForceCastMatch(
            name: String(line[nameRange]),
            expression: String(line[exprRange]).trimmingCharacters(in: .whitespaces),
            targetType: String(line[typeRange])
        )
    }

    private struct ForceTryMatch {
        let name: String
        let expression: String
    }

    private func extractForceTryAssignment(_ line: String) -> ForceTryMatch? {
        // Match: let/var name = try! expression
        let pattern = #"(let|var)\s+(\w+)\s*=\s*try!\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let nameRange = Range(match.range(at: 2), in: line),
              let exprRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        return ForceTryMatch(
            name: String(line[nameRange]),
            expression: String(line[exprRange]).trimmingCharacters(in: .whitespaces)
        )
    }
}
