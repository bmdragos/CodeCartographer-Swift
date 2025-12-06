import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Localization Analysis

struct LocalizationReport: Codable {
    let analyzedAt: String
    var totalStrings: Int
    var localizedStrings: Int
    var hardcodedStrings: Int
    var localizationCoverage: Double
    var hardcodedByFile: [String: Int]
    var hardcodedStrings_list: [HardcodedString]
    var localizationPatterns: [String: Int]
}

struct HardcodedString: Codable {
    let file: String
    let line: Int?
    let string: String
    let context: String?
    let likelyUserFacing: Bool
}

// MARK: - Localization Visitor

final class LocalizationVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var hardcodedStrings: [HardcodedString] = []
    private(set) var localizedCount = 0
    private(set) var localizationPatterns: Set<String> = []
    
    private var currentContext: String?
    
    // Patterns that indicate localization
    private let localizationPatternsList = [
        ".localize()", "NSLocalizedString", "LocalizedStringKey",
        "Text(\"", "Label(\"", ".localized", "L10n.", "Strings."
    ]
    
    // Strings that are likely not user-facing
    private let nonUserFacingPatterns = [
        "http", "https", "/", ".", "_", "com.", "identifier",
        "cell", "segue", "storyboard", "nib", "xib", "png", "jpg",
        "json", "xml", "plist", "key", "id", "ID", "uuid", "UUID"
    ]
    
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
    
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let content = extractStringContent(from: node)
        guard !content.isEmpty else { return .skipChildren }
        
        // Check if it's localized
        if let parent = node.parent?.description {
            for pattern in localizationPatternsList {
                if parent.contains(pattern) {
                    localizedCount += 1
                    localizationPatterns.insert(pattern)
                    return .skipChildren
                }
            }
        }
        
        // Check if it's likely user-facing
        let isLikelyUserFacing = isUserFacingString(content)
        
        // Skip very short strings or technical strings
        if content.count < 3 || !isLikelyUserFacing {
            return .skipChildren
        }
        
        hardcodedStrings.append(HardcodedString(
            file: filePath,
            line: lineNumber(for: node.position),
            string: String(content.prefix(100)),
            context: currentContext,
            likelyUserFacing: isLikelyUserFacing
        ))
        
        return .skipChildren
    }
    
    private func extractStringContent(from node: StringLiteralExprSyntax) -> String {
        // Get the string content without quotes
        var content = ""
        for segment in node.segments {
            if let stringSegment = segment.as(StringSegmentSyntax.self) {
                content += stringSegment.content.text
            }
        }
        return content
    }
    
    private func isUserFacingString(_ string: String) -> Bool {
        // Check for non-user-facing patterns
        for pattern in nonUserFacingPatterns {
            if string.lowercased().contains(pattern.lowercased()) {
                return false
            }
        }
        
        // Likely user-facing if it:
        // - Contains spaces (sentence-like)
        // - Starts with uppercase (title/sentence)
        // - Contains common UI words
        let hasSpaces = string.contains(" ")
        let startsWithUpper = string.first?.isUppercase ?? false
        let uiWords = ["button", "label", "title", "message", "error", "success", "please", "enter", "select"]
        let containsUIWord = uiWords.contains { string.lowercased().contains($0) }
        
        return hasSpaces || (startsWithUpper && string.count > 5) || containsUIWord
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

// MARK: - Localization Analyzer

class LocalizationAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> LocalizationReport {
        var allHardcoded: [HardcodedString] = []
        var totalLocalized = 0
        var hardcodedByFile: [String: Int] = [:]
        var allPatterns: [String: Int] = [:]
        
        for file in parsedFiles {
            let visitor = LocalizationVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            // Only count user-facing hardcoded strings
            let userFacing = visitor.hardcodedStrings.filter { $0.likelyUserFacing }
            allHardcoded.append(contentsOf: userFacing)
            totalLocalized += visitor.localizedCount
            
            if !userFacing.isEmpty {
                hardcodedByFile[file.relativePath] = userFacing.count
            }
            
            for pattern in visitor.localizationPatterns {
                allPatterns[pattern, default: 0] += 1
            }
        }
        
        let totalStrings = allHardcoded.count + totalLocalized
        let coverage = totalStrings > 0 ? Double(totalLocalized) / Double(totalStrings) * 100 : 100
        
        let dateFormatter = ISO8601DateFormatter()
        
        return LocalizationReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalStrings: totalStrings,
            localizedStrings: totalLocalized,
            hardcodedStrings: allHardcoded.count,
            localizationCoverage: coverage,
            hardcodedByFile: hardcodedByFile,
            hardcodedStrings_list: allHardcoded,
            localizationPatterns: allPatterns
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> LocalizationReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
