import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Test Coverage Analysis

struct TestCoverageReport: Codable {
    let analyzedAt: String
    var totalProductionFiles: Int
    var totalTestFiles: Int
    var activeTestFiles: Int      // Files actually in a test target
    var orphanedTestFiles: Int    // Test files not in any target
    var filesWithTests: Int
    var filesWithoutTests: Int
    var coveragePercentage: Double
    var testTargets: [TestTargetInfo]
    var testDetails: [TestFileInfo]
    var untestedFiles: [String]
    var testPatterns: [String: Int]
    var recommendations: [String]
}

struct TestTargetInfo: Codable {
    let name: String
    let fileCount: Int
    let testCount: Int
    let isUITest: Bool
}

struct TestFileInfo: Codable {
    let testFile: String
    let productionFile: String?  // inferred from name
    var testCount: Int
    var testNames: [String]
    var testTypes: [String]  // "unit", "integration", "ui"
    var inTarget: String?    // Which test target this file belongs to
    var isActive: Bool       // Whether it's in an active test target
}

// MARK: - Test Visitor

final class TestVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var isTestFile = false
    private(set) var testNames: [String] = []
    private(set) var testTypes: Set<String> = []
    private(set) var patterns: [String: Int] = [:]
    
    private var currentClassName: String?
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Detect XCTestCase subclass
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        currentClassName = node.name.text
        
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                let typeName = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if typeName == "XCTestCase" || typeName.contains("TestCase") {
                    isTestFile = true
                    testTypes.insert("unit")
                }
                if typeName.contains("UITest") {
                    isTestFile = true
                    testTypes.insert("ui")
                }
            }
        }
        
        return .visitChildren
    }
    
    // Detect test functions
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let funcName = node.name.text
        
        // Test functions start with "test"
        if funcName.hasPrefix("test") {
            testNames.append(funcName)
            isTestFile = true
            
            // Categorize test type
            let funcBody = node.description.lowercased()
            if funcBody.contains("xcuiapplication") || funcBody.contains("launch()") {
                testTypes.insert("ui")
            } else if funcBody.contains("urlsession") || funcBody.contains("network") {
                testTypes.insert("integration")
            } else {
                testTypes.insert("unit")
            }
        }
        
        // Detect async tests
        if node.signature.effectSpecifiers?.asyncSpecifier != nil && funcName.hasPrefix("test") {
            patterns["async tests", default: 0] += 1
        }
        
        return .visitChildren
    }
    
    // Detect test patterns
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // XCTest assertions
        let assertions = ["XCTAssert", "XCTAssertEqual", "XCTAssertNil", "XCTAssertNotNil",
                         "XCTAssertTrue", "XCTAssertFalse", "XCTAssertThrows", "XCTFail",
                         "XCTAssertNoThrow", "XCTAssertGreaterThan", "XCTAssertLessThan"]
        
        for assertion in assertions {
            if callText.hasPrefix(assertion) {
                patterns[assertion, default: 0] += 1
                break
            }
        }
        
        // Mocking patterns
        if callText.contains("Mock") || callText.contains("Stub") || callText.contains("Fake") {
            patterns["mocking", default: 0] += 1
        }
        
        // Expectation patterns
        if callText.contains("expectation") || callText.contains("fulfill") || callText.contains("wait(for:") {
            patterns["async expectations", default: 0] += 1
        }
        
        return .visitChildren
    }
    
    // Detect imports
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let importName = node.path.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if importName == "XCTest" {
            isTestFile = true
            patterns["XCTest", default: 0] += 1
        }
        if importName.contains("Testing") {
            patterns["Swift Testing", default: 0] += 1
        }
        if importName.contains("Quick") || importName.contains("Nimble") {
            patterns["Quick/Nimble", default: 0] += 1
        }
        return .skipChildren
    }
}

// MARK: - Test Coverage Analyzer

class TestCoverageAnalyzer {
    
    /// Analyze test coverage with optional target information
    func analyze(files: [URL], relativeTo root: URL, targetAnalysis: TargetAnalysis? = nil) -> TestCoverageReport {
        var testFiles: [TestFileInfo] = []
        var productionFiles: Set<String> = []
        var testedFiles: Set<String> = []
        var allPatterns: [String: Int] = [:]
        
        // Build target membership map
        var fileToTarget: [String: String] = [:]
        var testTargets: [TestTargetInfo] = []
        var testTargetFiles: Set<String> = []
        
        if let ta = targetAnalysis {
            // Identify test targets and their files
            for target in ta.targets {
                let isTestTarget = target.name.contains("Test") || target.name.contains("Spec")
                
                if isTestTarget {
                    // Count tests in this target
                    var targetTestCount = 0
                    for file in target.files {
                        fileToTarget[file] = target.name
                        testTargetFiles.insert(file)
                    }
                    
                    testTargets.append(TestTargetInfo(
                        name: target.name,
                        fileCount: target.files.count,
                        testCount: targetTestCount,  // Will update after parsing
                        isUITest: target.name.contains("UITest")
                    ))
                } else {
                    // Production target
                    for file in target.files {
                        fileToTarget[file] = target.name
                    }
                }
            }
        }
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let fileName = fileURL.lastPathComponent
            
            // Skip test files for production count
            let isInTestDir = relativePath.contains("Tests/") || relativePath.contains("Test/")
            let hasTestSuffix = fileName.contains("Test") || fileName.contains("Spec")
            
            let tree = Parser.parse(source: sourceText)
            let visitor = TestVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            if visitor.isTestFile || isInTestDir || hasTestSuffix {
                // This is a test file
                let inferredProductionFile = inferProductionFile(from: fileName)
                
                // Check if this test file is in an active test target
                let targetName = fileToTarget[fileName]
                let isActive = targetName != nil || testTargetFiles.contains(fileName)
                
                testFiles.append(TestFileInfo(
                    testFile: relativePath,
                    productionFile: inferredProductionFile,
                    testCount: visitor.testNames.count,
                    testNames: visitor.testNames,
                    testTypes: Array(visitor.testTypes),
                    inTarget: targetName,
                    isActive: isActive
                ))
                
                if let prodFile = inferredProductionFile {
                    testedFiles.insert(prodFile)
                }
                
                for (pattern, count) in visitor.patterns {
                    allPatterns[pattern, default: 0] += count
                }
            } else {
                // This is a production file
                productionFiles.insert(fileName)
            }
        }
        
        // Calculate active vs orphaned test files
        let activeTestFiles = testFiles.filter { $0.isActive }.count
        let orphanedTestFiles = testFiles.filter { !$0.isActive }.count
        
        // Calculate coverage
        let filesWithTests = productionFiles.intersection(testedFiles).count
        let filesWithoutTests = productionFiles.subtracting(testedFiles)
        let coverage = productionFiles.isEmpty ? 0 : Double(filesWithTests) / Double(productionFiles.count) * 100
        
        // Generate recommendations
        var recommendations: [String] = []
        
        if coverage < 30 {
            recommendations.append("Low test coverage (\(String(format: "%.1f", coverage))%) - prioritize critical path testing")
        }
        if allPatterns["async tests", default: 0] == 0 && allPatterns["async expectations", default: 0] > 0 {
            recommendations.append("Consider using async/await tests instead of expectations")
        }
        if allPatterns["mocking", default: 0] == 0 && testFiles.count > 10 {
            recommendations.append("No mocking detected - consider adding mocks for better isolation")
        }
        
        // Warn about orphaned tests
        if orphanedTestFiles > 0 {
            recommendations.append("⚠️ \(orphanedTestFiles) test files not in any test target - these won't run!")
        }
        
        // Warn if no test targets found
        if testTargets.isEmpty && targetAnalysis != nil {
            recommendations.append("⚠️ No test targets found in Xcode project - tests may not be configured")
        }
        
        // Find most important untested files
        let criticalUntested = filesWithoutTests.filter { file in
            let important = ["Manager", "Service", "Controller", "ViewModel", "Repository"]
            return important.contains { file.contains($0) }
        }
        
        if !criticalUntested.isEmpty {
            recommendations.append("Critical untested files: \(criticalUntested.prefix(5).joined(separator: ", "))")
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return TestCoverageReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalProductionFiles: productionFiles.count,
            totalTestFiles: testFiles.count,
            activeTestFiles: activeTestFiles,
            orphanedTestFiles: orphanedTestFiles,
            filesWithTests: filesWithTests,
            filesWithoutTests: filesWithoutTests.count,
            coveragePercentage: coverage,
            testTargets: testTargets,
            testDetails: testFiles.sorted { $0.testCount > $1.testCount },
            untestedFiles: Array(filesWithoutTests).sorted(),
            testPatterns: allPatterns,
            recommendations: recommendations
        )
    }
    
    private func inferProductionFile(from testFileName: String) -> String? {
        // AuthManagerTests.swift -> AuthManager.swift
        // AccountTests.swift -> Account.swift
        let prodName = testFileName
            .replacingOccurrences(of: "Tests.swift", with: ".swift")
            .replacingOccurrences(of: "Test.swift", with: ".swift")
            .replacingOccurrences(of: "Spec.swift", with: ".swift")
            .replacingOccurrences(of: "_Tests.swift", with: ".swift")
        
        if prodName == testFileName {
            return nil  // Couldn't infer
        }
        
        return prodName
    }
}
