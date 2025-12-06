import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - File Discovery

func findSwiftFiles(in directory: URL, excluding: [String] = [], includeTests: Bool = false) -> [URL] {
    let fm = FileManager.default
    
    // Resolve symlinks to get the real path
    let resolvedDirectory = directory.resolvingSymlinksInPath()
    
    guard let enumerator = fm.enumerator(at: resolvedDirectory, includingPropertiesForKeys: nil) else {
        return []
    }

    var result: [URL] = []
    var excludePatterns = ["Pods", ".build", "DerivedData", "Carthage", "xcodeproj", "xcworkspace"]
    
    // Only exclude Tests if not explicitly including them
    if !includeTests {
        excludePatterns.append("Tests")
    }
    
    // Add custom exclusions
    excludePatterns.append(contentsOf: excluding)
    
    for case let fileURL as URL in enumerator {
        let path = fileURL.path
        
        // Skip excluded directories
        if excludePatterns.contains(where: { path.contains($0) }) {
            continue
        }
        
        if fileURL.pathExtension == "swift" {
            result.append(fileURL)
        }
    }
    return result
}

/// Find Swift files including test directories (for test coverage analysis)
func findAllSwiftFiles(in directory: URL) -> [URL] {
    return findSwiftFiles(in: directory, includeTests: true)
}

// MARK: - Analysis

func analyzeFile(at url: URL, relativeTo root: URL) -> FileNode? {
    guard let sourceText = try? String(contentsOf: url) else {
        fputs("⚠️ Failed to read \(url.path)\n", stderr)
        return nil
    }
    
    let tree = Parser.parse(source: sourceText)
    let analyzer = FileAnalyzer(filePath: url.path, sourceText: sourceText)
    analyzer.walk(tree)
    
    // Make path relative
    let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")

    return FileNode(
        path: relativePath,
        imports: Array(analyzer.imports).sorted(),
        references: analyzer.references
    )
}

func buildSummary(from files: [FileNode]) -> AnalysisSummary {
    var singletonUsage: [String: Int] = [:]
    var fileRefCounts: [(String, Int)] = []
    
    for file in files {
        fileRefCounts.append((file.path, file.references.count))
        
        for ref in file.references {
            // Extract base singleton name
            let symbol = ref.symbol
            if let range = symbol.range(of: ".sharedInstance") {
                let base = String(symbol[..<range.lowerBound]) + ".sharedInstance()"
                singletonUsage[base, default: 0] += 1
            } else {
                singletonUsage[symbol, default: 0] += 1
            }
        }
    }
    
    // Top 10 hotspot files
    let hotspots = fileRefCounts
        .sorted { $0.1 > $1.1 }
        .prefix(10)
        .filter { $0.1 > 0 }
        .map { $0.0 }
    
    return AnalysisSummary(
        totalReferences: files.flatMap { $0.references }.count,
        singletonUsage: singletonUsage,
        hotspotFiles: Array(hotspots)
    )
}

// MARK: - Main

// Available analysis modes with descriptions
let analysisModes: [(flag: String, name: String, description: String)] = [
    ("--singletons", "Singletons", "Global state and singleton usage patterns"),
    ("--targets-only", "Targets", "Xcode target membership and orphaned files"),
    ("--auth-migration", "Auth Migration", "Authentication code tracking for migration"),
    ("--types", "Types", "Type definitions, protocols, inheritance hierarchy"),
    ("--tech-debt", "Tech Debt", "TODO/FIXME/HACK comment markers"),
    ("--functions", "Functions", "Function metrics (length, complexity, god functions)"),
    ("--delegates", "Delegates", "Delegate wiring patterns and potential issues"),
    ("--unused", "Unused Code", "Potentially dead code detection"),
    ("--network", "Network", "API endpoints and network call patterns"),
    ("--reactive", "Reactive", "RxSwift/Combine subscriptions and memory leaks"),
    ("--viewcontrollers", "ViewControllers", "ViewController lifecycle audit"),
    ("--smells", "Code Smells", "Force unwraps, magic numbers, deep nesting"),
    ("--localization", "Localization", "Hardcoded strings and i18n coverage"),
    ("--accessibility", "Accessibility", "Accessibility API coverage audit"),
    ("--threading", "Threading", "Thread safety and concurrency patterns"),
    ("--swiftui", "SwiftUI", "SwiftUI patterns and state management"),
    ("--uikit", "UIKit", "UIKit patterns and modernization score"),
    ("--tests", "Tests", "Test coverage with target awareness"),
    ("--deps", "Dependencies", "CocoaPods/SPM/Carthage analysis"),
    ("--coredata", "Core Data", "Core Data entities, fetch requests, contexts"),
    ("--docs", "Documentation", "Documentation coverage for public APIs"),
    ("--retain-cycles", "Retain Cycles", "Potential memory leaks and retain cycles"),
    ("--refactor", "Refactoring", "God functions with extraction suggestions"),
    ("--api", "API Surface", "Full type signatures, methods, properties"),
    ("--property TARGET", "Property Access", "Track all accesses to a specific pattern"),
    ("--impact SYMBOL", "Impact Analysis", "Analyze blast radius of changing a symbol"),
    ("--checklist", "Migration Checklist", "Generate phased migration plan from auth analysis"),
    ("--all", "All", "Run all analyses and combine output"),
]

func printHelp() {
    print("""
    CodeCartographer - Swift Static Analyzer for AI-Assisted Refactoring
    
    Usage: codecart <path> <mode> [options]
    
    Quick Start:
      codecart /path/to/project --list              Show all available analysis modes
      codecart /path/to/project --smells --verbose  Run code smell analysis
      codecart /path/to/project --all --verbose     Run all analyses
    
    Analysis Modes (22 available):
    """)
    
    for mode in analysisModes {
        let padding = String(repeating: " ", count: max(0, 20 - mode.flag.count))
        print("      \(mode.flag)\(padding) \(mode.description)")
    }
    
    print("""
    
    Options:
      --output FILE      Write JSON to file instead of stdout
      --verbose          Print progress and summaries to stderr
      --project FILE     Path to .xcodeproj for target analysis
      --list             Show all available analysis modes
      --help, -h         Show this help message
    
    Examples:
      codecart /path/to/project --smells --verbose
      codecart /path/to/project --auth-migration --verbose
      codecart /path/to/project --functions --output report.json
      codecart /path/to/project --tests --verbose
      codecart /path/to/project --all --project "App.xcodeproj" --verbose
    """)
}

func printModeList() {
    print("""
    CodeCartographer - Available Analysis Modes
    
    """)
    
    print("┌─────────────────────┬────────────────────────────────────────────────────┐")
    print("│ Mode                │ Description                                        │")
    print("├─────────────────────┼────────────────────────────────────────────────────┤")
    
    for mode in analysisModes {
        let flagPadded = mode.flag.padding(toLength: 19, withPad: " ", startingAt: 0)
        let descPadded = mode.description.padding(toLength: 50, withPad: " ", startingAt: 0)
        print("│ \(flagPadded) │ \(descPadded) │")
    }
    
    print("└─────────────────────┴────────────────────────────────────────────────────┘")
    print("")
    print("Usage: codecart <path> <mode> [--verbose] [--output file.json]")
    print("")
}

func main() {
    let args = CommandLine.arguments
    
    // Show help if no args, --help, or -h
    if args.count < 2 || args.contains("--help") || args.contains("-h") {
        printHelp()
        return
    }
    
    // Show mode list
    if args.contains("--list") {
        printModeList()
        return
    }
    
    // Show version
    if args.contains("--version") || args.contains("-v") {
        print("CodeCartographer v1.0.0")
        print("Swift Static Analyzer for AI-Assisted Refactoring")
        return
    }
    
    // Check if first arg is a path (not a flag)
    let firstArg = args[1]
    if firstArg.hasPrefix("-") {
        print("Error: First argument must be a path to your Swift project")
        print("")
        printHelp()
        return
    }
    
    // Check if no analysis mode specified
    let hasAnalysisMode = args.dropFirst(2).contains { arg in
        analysisModes.contains { $0.flag.hasPrefix(arg) } || arg == "--all"
    }
    
    if !hasAnalysisMode && args.count == 2 {
        print("Error: No analysis mode specified")
        print("")
        print("Available modes:")
        for mode in analysisModes.prefix(10) {
            print("  \(mode.flag.padding(toLength: 20, withPad: " ", startingAt: 0)) \(mode.description)")
        }
        print("  ... and \(analysisModes.count - 10) more (use --list to see all)")
        print("")
        print("Example: codecart \(firstArg) --smells --verbose")
        return
    }
    
    // Legacy support: if only path + --verbose, show help
    if args.count == 3 && args.contains("--verbose") {
        print("Error: No analysis mode specified")
        print("")
        print("Example: codecart \(firstArg) --smells --verbose")
        print("Use --list to see all available modes")
        return
    }

    let inputPath = args[1]
    let fm = FileManager.default
    
    // Validate path exists
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: inputPath, isDirectory: &isDirectory) else {
        fputs("❌ Error: Path does not exist: \(inputPath)\n", stderr)
        exit(1)
    }
    
    // Handle single file vs directory
    let rootPath: String
    let rootURL: URL
    var singleFileMode: URL? = nil
    
    if isDirectory.boolValue {
        rootPath = inputPath
        rootURL = URL(fileURLWithPath: inputPath)
    } else if inputPath.hasSuffix(".swift") {
        // Single file mode - analyze just this file
        let fileURL = URL(fileURLWithPath: inputPath)
        rootPath = fileURL.deletingLastPathComponent().path
        rootURL = fileURL.deletingLastPathComponent()
        singleFileMode = fileURL
    } else {
        fputs("❌ Error: Path must be a directory or .swift file: \(inputPath)\n", stderr)
        exit(1)
    }
    
    let verbose = args.contains("--verbose")
    let singletonsMode = args.contains("--singletons")
    let targetsOnly = args.contains("--targets-only")
    let authMigration = args.contains("--auth-migration")
    let typesOnly = args.contains("--types")
    let techDebt = args.contains("--tech-debt")
    let functionsMode = args.contains("--functions")
    let delegatesMode = args.contains("--delegates")
    let unusedMode = args.contains("--unused")
    let networkMode = args.contains("--network")
    let reactiveMode = args.contains("--reactive")
    let vcMode = args.contains("--viewcontrollers")
    let smellsMode = args.contains("--smells")
    let localizationMode = args.contains("--localization")
    let accessibilityMode = args.contains("--accessibility")
    let checklistMode = args.contains("--checklist")
    let threadingMode = args.contains("--threading")
    let swiftuiMode = args.contains("--swiftui")
    let uikitMode = args.contains("--uikit")
    let testsMode = args.contains("--tests")
    let depsMode = args.contains("--deps")
    let coredataMode = args.contains("--coredata")
    let docsMode = args.contains("--docs")
    let retainCyclesMode = args.contains("--retain-cycles")
    let refactorMode = args.contains("--refactor")
    let apiMode = args.contains("--api")
    let runAll = args.contains("--all")
    
    // Property tracking target
    var propertyTarget: String? = nil
    if let propIndex = args.firstIndex(of: "--property"), propIndex + 1 < args.count {
        propertyTarget = args[propIndex + 1]
    }
    
    // Impact analysis target
    var impactTarget: String? = nil
    if let impactIndex = args.firstIndex(of: "--impact"), impactIndex + 1 < args.count {
        impactTarget = args[impactIndex + 1]
    }
    
    var outputFile: String? = nil
    if let outputIndex = args.firstIndex(of: "--output"), outputIndex + 1 < args.count {
        outputFile = args[outputIndex + 1]
    }
    
    var projectPath: String? = nil
    if let projectIndex = args.firstIndex(of: "--project"), projectIndex + 1 < args.count {
        let proj = args[projectIndex + 1]
        // Handle relative or absolute path
        if proj.hasPrefix("/") {
            projectPath = proj + "/project.pbxproj"
        } else {
            projectPath = rootPath + "/" + proj + "/project.pbxproj"
        }
    }

    if verbose {
        if let singleFile = singleFileMode {
            fputs("🗺️  CodeCartographer analyzing: \(singleFile.lastPathComponent)\n", stderr)
        } else {
            fputs("🗺️  CodeCartographer analyzing: \(rootPath)\n", stderr)
        }
    }
    
    // Find Swift files - single file or directory scan
    let swiftFiles: [URL]
    if let singleFile = singleFileMode {
        swiftFiles = [singleFile]
    } else {
        swiftFiles = findSwiftFiles(in: rootURL)
    }
    
    if verbose {
        fputs("📁 Found \(swiftFiles.count) Swift file\(swiftFiles.count == 1 ? "" : "s")\n", stderr)
    }
    
    // Target analysis
    var targetAnalysis: TargetAnalysis? = nil
    if let projectPath = projectPath {
        if verbose {
            fputs("📦 Analyzing Xcode project targets...\n", stderr)
        }
        let targetAnalyzer = TargetAnalyzer(projectPath: projectPath, repoRoot: rootPath)
        targetAnalysis = targetAnalyzer.analyze()
        
        if verbose, let ta = targetAnalysis {
            fputs("   Found \(ta.targets.count) targets\n", stderr)
            for target in ta.targets {
                fputs("   - \(target.name): \(target.files.count) files\n", stderr)
            }
            fputs("   Orphaned files: \(ta.orphanedFiles.count)\n", stderr)
        }
    }
    
    // If targets-only, just output that
    if targetsOnly {
        guard let ta = targetAnalysis else {
            fputs("❌ --targets-only requires --project\n", stderr)
            exit(1)
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(ta)
            if let outputFile = outputFile {
                try data.write(to: URL(fileURLWithPath: outputFile))
            } else {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            fputs("❌ Failed to encode JSON: \(error)\n", stderr)
            exit(1)
        }
        return
    }
    
    // Auth migration analysis
    if authMigration || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runAuthMigrationAnalysis(ctx: ctx, isSpecificMode: authMigration, runAll: runAll) { return }
    }
    
    // Types analysis
    if typesOnly || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runTypesAnalysis(ctx: ctx, isSpecificMode: typesOnly, runAll: runAll) { return }
    }
    
    // Tech debt analysis
    if techDebt || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runTechDebtAnalysis(ctx: ctx, isSpecificMode: techDebt, runAll: runAll) { return }
    }
    
    // Function metrics analysis
    if functionsMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runFunctionsAnalysis(ctx: ctx, isSpecificMode: functionsMode, runAll: runAll) { return }
    }
    
    // Delegate wiring analysis
    if delegatesMode || runAll {
        var ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        // Note: runDelegatesAnalysis creates typeMap internally if not provided
        if runDelegatesAnalysis(ctx: ctx, isSpecificMode: delegatesMode, runAll: runAll) { return }
    }
    
    // Unused code analysis
    if unusedMode || runAll {
        var ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if let ta = targetAnalysis {
            ctx.targetFiles = Set(ta.targets.flatMap { $0.files })
        }
        if runUnusedAnalysis(ctx: ctx, isSpecificMode: unusedMode, runAll: runAll) { return }
    }
    
    // Network analysis
    if networkMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runNetworkAnalysis(ctx: ctx, isSpecificMode: networkMode, runAll: runAll) { return }
    }
    
    // Reactive (RxSwift/Combine) analysis
    if reactiveMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runReactiveAnalysis(ctx: ctx, isSpecificMode: reactiveMode, runAll: runAll) { return }
    }
    
    // ViewController lifecycle analysis
    if vcMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runViewControllersAnalysis(ctx: ctx, isSpecificMode: vcMode, runAll: runAll) { return }
    }
    
    // Code smells analysis
    if smellsMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runSmellsAnalysis(ctx: ctx, isSpecificMode: smellsMode, runAll: runAll) { return }
    }
    
    // Localization analysis
    if localizationMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runLocalizationAnalysis(ctx: ctx, isSpecificMode: localizationMode, runAll: runAll) { return }
    }
    
    // Accessibility analysis
    if accessibilityMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runAccessibilityAnalysis(ctx: ctx, isSpecificMode: accessibilityMode, runAll: runAll) { return }
    }
    
    // Property access tracking
    if let target = propertyTarget {
        if verbose {
            fputs("🔍 Tracking property accesses for: \(target)\n", stderr)
        }
        
        let propAnalyzer = PropertyAccessAnalyzer()
        let propReport = propAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL, targetPattern: target)
        
        if verbose {
            fputs("   Total accesses: \(propReport.totalAccesses)\n", stderr)
            fputs("   Properties found: \(propReport.properties.count)\n", stderr)
            
            fputs("\n📊 Property breakdown:\n", stderr)
            for prop in propReport.properties.prefix(15) {
                fputs("     \(prop.propertyName): \(prop.readCount)R/\(prop.writeCount)W/\(prop.callCount)C in \(prop.fileCount) files\n", stderr)
            }
        }
        
        outputJSON(propReport, to: outputFile)
        return
    }
    
    // Migration checklist generation
    if checklistMode {
        if verbose {
            fputs("📋 Generating migration checklist...\n", stderr)
        }
        
        // First run auth analysis
        let authAnalyzer = AuthMigrationAnalyzer()
        let authReport = authAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        // Generate checklist
        let generator = MigrationChecklistGenerator()
        let checklist = generator.generateAuthMigrationChecklist(from: authReport)
        
        if verbose {
            fputs("   Total tasks: \(checklist.totalTasks)\n", stderr)
            fputs("   Estimated effort: \(checklist.estimatedEffort)\n", stderr)
            fputs("   Phases: \(checklist.phases.count)\n", stderr)
            
            for phase in checklist.phases {
                fputs("     - \(phase.name): \(phase.tasks.count) tasks\n", stderr)
            }
            
            // Also output markdown to stderr for quick viewing
            fputs("\n" + checklist.markdownOutput + "\n", stderr)
        }
        
        outputJSON(checklist, to: outputFile)
        return
    }
    
    // Impact analysis
    if let target = impactTarget {
        if verbose {
            fputs("💥 Analyzing impact of changing: \(target)\n", stderr)
        }
        
        let impactAnalyzer = ImpactAnalyzer()
        let impactReport = impactAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL, targetSymbol: target)
        
        if verbose {
            fputs("   Impact score: \(impactReport.impactScore)\n", stderr)
            fputs("   Files affected: \(impactReport.totalImpactedFiles)\n", stderr)
            fputs("   Safe to modify: \(impactReport.safeToModify ? "Yes" : "No")\n", stderr)
            
            if !impactReport.warnings.isEmpty {
                fputs("\n⚠️ Warnings:\n", stderr)
                for warning in impactReport.warnings {
                    fputs("     \(warning)\n", stderr)
                }
            }
            
            fputs("\n📁 Top affected files:\n", stderr)
            for dep in impactReport.directDependents.prefix(10) {
                fputs("     \(dep.file): \(dep.usageCount) uses (\(dep.usageTypes.joined(separator: ", ")))\n", stderr)
            }
        }
        
        outputJSON(impactReport, to: outputFile)
        return
    }
    
    // Thread safety analysis
    if threadingMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runThreadingAnalysis(ctx: ctx, isSpecificMode: threadingMode, runAll: runAll) { return }
    }
    
    // SwiftUI analysis
    if swiftuiMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runSwiftUIAnalysis(ctx: ctx, isSpecificMode: swiftuiMode, runAll: runAll) { return }
    }
    
    // UIKit analysis
    if uikitMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runUIKitAnalysis(ctx: ctx, isSpecificMode: uikitMode, runAll: runAll) { return }
    }
    
    // Test coverage analysis
    if testsMode || runAll {
        if verbose {
            fputs("🧪 Running test coverage analysis...\n", stderr)
        }
        
        // For test coverage, scan parent directory to find sibling test folders
        // e.g., "MyApp" has sibling "MyAppTests"
        let parentURL = rootURL.deletingLastPathComponent()
        let allFilesIncludingTests = findAllSwiftFiles(in: parentURL)
        
        if verbose {
            fputs("   Scanning parent directory for tests: \(parentURL.path)\n", stderr)
            fputs("   Found \(allFilesIncludingTests.count) total Swift files (including tests)\n", stderr)
        }
        
        // Also analyze targets in parent directory for test target detection
        var parentTargetAnalysis: TargetAnalysis? = nil
        if projectPath != nil {
            // Use existing target analysis
            parentTargetAnalysis = targetAnalysis
        } else {
            // Try to find xcodeproj in parent directory
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(atPath: parentURL.path) {
                for item in contents {
                    if item.hasSuffix(".xcodeproj") {
                        // Need to append /project.pbxproj to the xcodeproj directory
                        let projPath = parentURL.appendingPathComponent(item).appendingPathComponent("project.pbxproj").path
                        if verbose {
                            fputs("   Found Xcode project: \(item)\n", stderr)
                        }
                        let targetAnalyzer = TargetAnalyzer(projectPath: projPath, repoRoot: parentURL.path)
                        parentTargetAnalysis = targetAnalyzer.analyze()
                        break
                    }
                }
            }
        }
        
        let testAnalyzer = TestCoverageAnalyzer()
        let testReport = testAnalyzer.analyze(files: allFilesIncludingTests, relativeTo: parentURL, targetAnalysis: parentTargetAnalysis)
        
        if verbose {
            fputs("   Production files: \(testReport.totalProductionFiles)\n", stderr)
            fputs("   Test files: \(testReport.totalTestFiles)\n", stderr)
            fputs("   Active test files: \(testReport.activeTestFiles)\n", stderr)
            fputs("   Orphaned test files: \(testReport.orphanedTestFiles)\n", stderr)
            fputs("   Files with tests: \(testReport.filesWithTests)\n", stderr)
            fputs("   Coverage: \(String(format: "%.1f", testReport.coveragePercentage))%\n", stderr)
            
            if !testReport.testTargets.isEmpty {
                fputs("\n🎯 Test targets:\n", stderr)
                for target in testReport.testTargets {
                    let type = target.isUITest ? "UI" : "Unit"
                    fputs("     \(target.name) (\(type)): \(target.fileCount) files\n", stderr)
                }
            }
            
            if !testReport.testPatterns.isEmpty {
                fputs("\n🔬 Test patterns:\n", stderr)
                for (pattern, count) in testReport.testPatterns.sorted(by: { $0.value > $1.value }).prefix(8) {
                    fputs("     \(pattern): \(count)\n", stderr)
                }
            }
            
            if !testReport.recommendations.isEmpty {
                fputs("\n💡 Recommendations:\n", stderr)
                for rec in testReport.recommendations {
                    fputs("     • \(rec)\n", stderr)
                }
            }
        }
        
        if testsMode && !runAll {
            outputJSON(testReport, to: outputFile)
            return
        }
    }
    
    // Dependency manager analysis (CocoaPods, SPM, Carthage)
    if depsMode || runAll {
        if verbose {
            fputs("📦 Running dependency analysis...\n", stderr)
        }
        
        // Find the project root by searching upward for dependency files
        func findProjectRoot(from start: URL) -> URL {
            var current = start
            let fm = FileManager.default
            for _ in 0..<5 {  // Search up to 5 levels
                if fm.fileExists(atPath: current.appendingPathComponent("Package.swift").path) ||
                   fm.fileExists(atPath: current.appendingPathComponent("Podfile").path) ||
                   fm.fileExists(atPath: current.appendingPathComponent("Cartfile").path) ||
                   fm.fileExists(atPath: current.appendingPathComponent(".xcodeproj").path) {
                    return current
                }
                let parent = current.deletingLastPathComponent()
                if parent == current { break }
                current = parent
            }
            return start  // Fallback to original
        }
        
        let projectRoot = findProjectRoot(from: rootURL)
        let depAnalyzer = DependencyManagerAnalyzer()
        let depReport = depAnalyzer.analyze(projectRoot: projectRoot)
        
        if verbose {
            fputs("   Podfile: \(depReport.hasPodfile ? "✓" : "✗")\n", stderr)
            fputs("   Package.swift: \(depReport.hasPackageSwift ? "✓" : "✗")\n", stderr)
            fputs("   Cartfile: \(depReport.hasCartfile ? "✓" : "✗")\n", stderr)
            fputs("   Total dependencies: \(depReport.totalDependencies)\n", stderr)
            
            if !depReport.pods.isEmpty {
                fputs("\n📱 CocoaPods (\(depReport.pods.count) unique):\n", stderr)
                for pod in depReport.pods.sorted(by: { $0.name < $1.name }).prefix(20) {
                    let version = pod.version ?? "latest"
                    let subspec = pod.subspecs.isEmpty ? "" : "/\(pod.subspecs.joined(separator: "/"))"
                    let targets = pod.targets.isEmpty ? "" : " [\(pod.targets.joined(separator: ", "))]"
                    fputs("     \(pod.name)\(subspec) \(version)\(targets)\n", stderr)
                }
                if depReport.pods.count > 20 {
                    fputs("     ... and \(depReport.pods.count - 20) more\n", stderr)
                }
            }
            
            if !depReport.podsByTarget.isEmpty {
                fputs("\n🎯 Pods by target:\n", stderr)
                for (target, pods) in depReport.podsByTarget.sorted(by: { $0.key < $1.key }) {
                    fputs("     \(target): \(pods.count) pods\n", stderr)
                }
            }
            
            if !depReport.recommendations.isEmpty {
                fputs("\n💡 Recommendations:\n", stderr)
                for rec in depReport.recommendations {
                    fputs("     • \(rec)\n", stderr)
                }
            }
        }
        
        if depsMode && !runAll {
            outputJSON(depReport, to: outputFile)
            return
        }
    }
    
    // Core Data analysis
    if coredataMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runCoreDataAnalysis(ctx: ctx, isSpecificMode: coredataMode, runAll: runAll) { return }
    }
    
    // Documentation coverage analysis
    if docsMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runDocsAnalysis(ctx: ctx, isSpecificMode: docsMode, runAll: runAll) { return }
    }
    
    // Retain cycle analysis
    if retainCyclesMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runRetainCyclesAnalysis(ctx: ctx, isSpecificMode: retainCyclesMode, runAll: runAll) { return }
    }
    
    // Refactoring analysis
    if refactorMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runRefactoringAnalysis(ctx: ctx, isSpecificMode: refactorMode, runAll: runAll) { return }
    }
    
    // API surface analysis
    if apiMode || runAll {
        let ctx = AnalysisContext(files: swiftFiles, rootURL: rootURL, rootPath: rootPath, verbose: verbose, outputFile: outputFile)
        if runAPIAnalysis(ctx: ctx, isSpecificMode: apiMode, runAll: runAll) { return }
    }
    
    // Singleton/global state analysis (explicit mode required now)
    if singletonsMode || runAll {
        var nodes: [FileNode] = []
        
        if verbose {
            fputs("📊 Running singleton analysis...\n", stderr)
        }
        
        for (index, fileURL) in swiftFiles.enumerated() {
            if verbose && index % 100 == 0 && index > 0 {
                fputs("   Analyzing... \(index)/\(swiftFiles.count)\n", stderr)
            }
            
            if let node = analyzeFile(at: fileURL, relativeTo: rootURL) {
                if !node.references.isEmpty || !node.imports.isEmpty {
                    nodes.append(node)
                }
            }
        }
        
        let summary = buildSummary(from: nodes)
        
        let dateFormatter = ISO8601DateFormatter()
        let result = ExtendedAnalysisResult(
            analyzedAt: dateFormatter.string(from: Date()),
            rootPath: rootPath,
            fileCount: swiftFiles.count,
            files: nodes.sorted { $0.references.count > $1.references.count },
            summary: summary,
            targets: targetAnalysis
        )
        
        if verbose {
            fputs("\n📈 Summary:\n", stderr)
            fputs("   Total files analyzed: \(swiftFiles.count)\n", stderr)
            fputs("   Files with references: \(nodes.count)\n", stderr)
            fputs("   Total references: \(summary.totalReferences)\n", stderr)
            fputs("\n🔥 Top singletons:\n", stderr)
            for (symbol, count) in summary.singletonUsage.sorted(by: { $0.value > $1.value }).prefix(10) {
                fputs("   \(count)x \(symbol)\n", stderr)
            }
        }
        
        if singletonsMode && !runAll {
            outputJSON(result, to: outputFile)
            return
        }
    }
}

// MARK: - Helper

func outputJSON<T: Encodable>(_ value: T, to outputFile: String?) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    
    do {
        let data = try encoder.encode(value)
        if let outputFile = outputFile {
            try data.write(to: URL(fileURLWithPath: outputFile))
        } else {
            FileHandle.standardOutput.write(data)
        }
    } catch {
        fputs("❌ Failed to encode JSON: \(error)\n", stderr)
        exit(1)
    }
}

main()
