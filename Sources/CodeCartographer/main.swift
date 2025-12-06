import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - File Discovery

func findSwiftFiles(in directory: URL, excluding: [String] = [], includeTests: Bool = false) -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
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

    let rootPath = args[1]
    let rootURL = URL(fileURLWithPath: rootPath)
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
        fputs("🗺️  CodeCartographer analyzing: \(rootPath)\n", stderr)
    }
    
    // Find all Swift files once
    let swiftFiles = findSwiftFiles(in: rootURL)
    if verbose {
        fputs("📁 Found \(swiftFiles.count) Swift files\n", stderr)
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
        if verbose {
            fputs("🔐 Running auth migration analysis...\n", stderr)
        }
        
        let authAnalyzer = AuthMigrationAnalyzer()
        let authReport = authAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total auth accesses: \(authReport.totalAccesses)\n", stderr)
            fputs("   Properties tracked: \(authReport.accessesByProperty.count)\n", stderr)
            fputs("\n🔑 Top auth properties:\n", stderr)
            for item in authReport.migrationPriority.prefix(10) {
                fputs("   \(item.totalAccesses)x \(item.property) (\(item.fileCount) files)\n", stderr)
            }
        }
        
        if authMigration && !runAll {
            outputJSON(authReport, to: outputFile)
            return
        }
    }
    
    // Types analysis
    if typesOnly || runAll {
        if verbose {
            fputs("📐 Running type definition analysis...\n", stderr)
        }
        
        let depAnalyzer = DependencyGraphAnalyzer()
        let typeMap = depAnalyzer.analyzeTypes(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Types defined: \(typeMap.definitions.count)\n", stderr)
            fputs("   Protocols: \(typeMap.definitions.filter { $0.kind == .protocol }.count)\n", stderr)
            fputs("   Classes: \(typeMap.definitions.filter { $0.kind == .class }.count)\n", stderr)
            fputs("   Structs: \(typeMap.definitions.filter { $0.kind == .struct }.count)\n", stderr)
            
            // Show most-implemented protocols
            let topProtocols = typeMap.protocolConformances.sorted { $0.value.count > $1.value.count }.prefix(5)
            if !topProtocols.isEmpty {
                fputs("\n📋 Most implemented protocols:\n", stderr)
                for (proto, conformers) in topProtocols {
                    fputs("   \(proto): \(conformers.count) conformers\n", stderr)
                }
            }
        }
        
        if typesOnly && !runAll {
            outputJSON(typeMap, to: outputFile)
            return
        }
    }
    
    // Tech debt analysis
    if techDebt || runAll {
        if verbose {
            fputs("📝 Running tech debt analysis...\n", stderr)
        }
        
        let debtAnalyzer = TechDebtAnalyzer()
        let debtReport = debtAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total markers: \(debtReport.totalMarkers)\n", stderr)
            fputs("   By type:\n", stderr)
            for (type, count) in debtReport.markersByType.sorted(by: { $0.value > $1.value }) {
                fputs("     \(type): \(count)\n", stderr)
            }
            if !debtReport.hotspotFiles.isEmpty {
                fputs("   Hotspot files:\n", stderr)
                for file in debtReport.hotspotFiles.prefix(5) {
                    fputs("     \(file): \(debtReport.markersByFile[file] ?? 0) markers\n", stderr)
                }
            }
        }
        
        if techDebt && !runAll {
            outputJSON(debtReport, to: outputFile)
            return
        }
    }
    
    // Function metrics analysis
    if functionsMode || runAll {
        if verbose {
            fputs("📏 Running function metrics analysis...\n", stderr)
        }
        
        let metricsAnalyzer = FunctionMetricsAnalyzer()
        let metricsReport = metricsAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total functions: \(metricsReport.totalFunctions)\n", stderr)
            fputs("   Average line count: \(String(format: "%.1f", metricsReport.averageLineCount))\n", stderr)
            fputs("   Average complexity: \(String(format: "%.1f", metricsReport.averageComplexity))\n", stderr)
            fputs("   God functions (>50 lines or complexity >10): \(metricsReport.godFunctions.count)\n", stderr)
            if !metricsReport.godFunctions.isEmpty {
                fputs("\n⚠️ Top god functions:\n", stderr)
                for fn in metricsReport.godFunctions.prefix(10) {
                    fputs("     \(fn.name) in \(fn.file): \(fn.lineCount) lines, complexity \(fn.complexity)\n", stderr)
                }
            }
        }
        
        if functionsMode && !runAll {
            outputJSON(metricsReport, to: outputFile)
            return
        }
    }
    
    // Delegate wiring analysis
    if delegatesMode || runAll {
        if verbose {
            fputs("🔗 Running delegate wiring analysis...\n", stderr)
        }
        
        // Need type map for this
        let depAnalyzer = DependencyGraphAnalyzer()
        let typeMap = depAnalyzer.analyzeTypes(files: swiftFiles, relativeTo: rootURL)
        
        let delegateAnalyzer = DelegateAnalyzer()
        let delegateReport = delegateAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL, typeMap: typeMap)
        
        if verbose {
            fputs("   Total delegate assignments: \(delegateReport.totalDelegateAssignments)\n", stderr)
            fputs("   Delegate protocols found: \(delegateReport.delegateProtocols.count)\n", stderr)
            fputs("   Potential issues: \(delegateReport.potentialIssues.count)\n", stderr)
            
            if !delegateReport.delegateProtocols.isEmpty {
                fputs("\n📋 Top delegate protocols:\n", stderr)
                for proto in delegateReport.delegateProtocols.prefix(5) {
                    fputs("     \(proto.protocolName): \(proto.implementers.count) implementers\n", stderr)
                }
            }
        }
        
        if delegatesMode && !runAll {
            outputJSON(delegateReport, to: outputFile)
            return
        }
    }
    
    // Unused code analysis
    if unusedMode || runAll {
        if verbose {
            fputs("🗑️  Running unused code analysis...\n", stderr)
        }
        
        // Get target files if available
        var targetFiles: Set<String>? = nil
        if let ta = targetAnalysis {
            targetFiles = Set(ta.targets.flatMap { $0.files })
        }
        
        let unusedAnalyzer = UnusedCodeAnalyzer()
        let unusedReport = unusedAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL, targetFiles: targetFiles)
        
        if verbose {
            fputs("   Potentially unused types: \(unusedReport.potentiallyUnusedTypes.count)\n", stderr)
            fputs("   Potentially unused functions: \(unusedReport.potentiallyUnusedFunctions.count)\n", stderr)
            fputs("   Estimated dead lines: ~\(unusedReport.summary.estimatedDeadLines)\n", stderr)
            
            if !unusedReport.potentiallyUnusedTypes.isEmpty {
                fputs("\n🗑️  Sample unused types:\n", stderr)
                for item in unusedReport.potentiallyUnusedTypes.prefix(10) {
                    fputs("     \(item.name) (\(item.kind)) in \(item.file)\n", stderr)
                }
            }
        }
        
        if unusedMode && !runAll {
            outputJSON(unusedReport, to: outputFile)
            return
        }
    }
    
    // Network analysis
    if networkMode || runAll {
        if verbose {
            fputs("🌐 Running network call analysis...\n", stderr)
        }
        
        let networkAnalyzer = NetworkAnalyzer()
        let networkReport = networkAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total endpoints found: \(networkReport.totalEndpoints)\n", stderr)
            fputs("   Files with network code: \(networkReport.totalNetworkFiles)\n", stderr)
            
            if !networkReport.networkPatterns.isEmpty {
                fputs("\n🔌 Network patterns:\n", stderr)
                for pattern in networkReport.networkPatterns.prefix(5) {
                    fputs("     \(pattern.pattern): \(pattern.count) uses - \(pattern.description)\n", stderr)
                }
            }
            
            if !networkReport.endpoints.isEmpty {
                fputs("\n📡 Sample endpoints:\n", stderr)
                for endpoint in networkReport.endpoints.prefix(10) {
                    let method = endpoint.method ?? "?"
                    fputs("     [\(method)] \(endpoint.endpoint)\n", stderr)
                }
            }
        }
        
        if networkMode && !runAll {
            outputJSON(networkReport, to: outputFile)
            return
        }
    }
    
    // Reactive (RxSwift/Combine) analysis
    if reactiveMode || runAll {
        if verbose {
            fputs("⚡ Running reactive analysis...\n", stderr)
        }
        
        let reactiveAnalyzer = ReactiveAnalyzer()
        let reactiveReport = reactiveAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Framework: \(reactiveReport.framework)\n", stderr)
            fputs("   Total subscriptions: \(reactiveReport.totalSubscriptions)\n", stderr)
            fputs("   DisposeBags: \(reactiveReport.totalDisposeBags)\n", stderr)
            fputs("   Potential leaks: \(reactiveReport.potentialLeaks.count)\n", stderr)
            
            if !reactiveReport.potentialLeaks.isEmpty {
                fputs("\n⚠️ Potential memory leaks:\n", stderr)
                for leak in reactiveReport.potentialLeaks.prefix(10) {
                    fputs("     \(leak.file):\(leak.line ?? 0) - \(leak.description)\n", stderr)
                }
            }
        }
        
        if reactiveMode && !runAll {
            outputJSON(reactiveReport, to: outputFile)
            return
        }
    }
    
    // ViewController lifecycle analysis
    if vcMode || runAll {
        if verbose {
            fputs("📱 Running ViewController analysis...\n", stderr)
        }
        
        let vcAnalyzer = ViewControllerAnalyzer()
        let vcReport = vcAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total ViewControllers: \(vcReport.totalViewControllers)\n", stderr)
            fputs("   Lifecycle issues: \(vcReport.issues.count)\n", stderr)
            fputs("   Heavy lifecycle methods: \(vcReport.heavyLifecycleMethods.count)\n", stderr)
            
            if !vcReport.lifecycleOverrides.isEmpty {
                fputs("\n📋 Lifecycle overrides:\n", stderr)
                for (method, count) in vcReport.lifecycleOverrides.sorted(by: { $0.value > $1.value }).prefix(5) {
                    fputs("     \(method): \(count) VCs\n", stderr)
                }
            }
        }
        
        if vcMode && !runAll {
            outputJSON(vcReport, to: outputFile)
            return
        }
    }
    
    // Code smells analysis
    if smellsMode || runAll {
        if verbose {
            fputs("🦨 Running code smell analysis...\n", stderr)
        }
        
        let smellAnalyzer = CodeSmellAnalyzer()
        let smellReport = smellAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total smells: \(smellReport.totalSmells)\n", stderr)
            fputs("\n🔍 Smells by type:\n", stderr)
            for (type, count) in smellReport.smellsByType.sorted(by: { $0.value > $1.value }) {
                fputs("     \(type): \(count)\n", stderr)
            }
            
            if !smellReport.hotspotFiles.isEmpty {
                fputs("\n🔥 Hotspot files:\n", stderr)
                for file in smellReport.hotspotFiles.prefix(5) {
                    fputs("     \(file): \(smellReport.smellsByFile[file] ?? 0) smells\n", stderr)
                }
            }
        }
        
        if smellsMode && !runAll {
            outputJSON(smellReport, to: outputFile)
            return
        }
    }
    
    // Localization analysis
    if localizationMode || runAll {
        if verbose {
            fputs("🌍 Running localization analysis...\n", stderr)
        }
        
        let locAnalyzer = LocalizationAnalyzer()
        let locReport = locAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total strings: \(locReport.totalStrings)\n", stderr)
            fputs("   Localized: \(locReport.localizedStrings)\n", stderr)
            fputs("   Hardcoded: \(locReport.hardcodedStrings)\n", stderr)
            fputs("   Coverage: \(String(format: "%.1f", locReport.localizationCoverage))%\n", stderr)
            
            if !locReport.localizationPatterns.isEmpty {
                fputs("\n🔤 Localization patterns used:\n", stderr)
                for (pattern, count) in locReport.localizationPatterns.sorted(by: { $0.value > $1.value }) {
                    fputs("     \(pattern): \(count) uses\n", stderr)
                }
            }
        }
        
        if localizationMode && !runAll {
            outputJSON(locReport, to: outputFile)
            return
        }
    }
    
    // Accessibility analysis
    if accessibilityMode || runAll {
        if verbose {
            fputs("♿ Running accessibility analysis...\n", stderr)
        }
        
        let a11yAnalyzer = AccessibilityAnalyzer()
        let a11yReport = a11yAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   UI elements: \(a11yReport.totalUIElements)\n", stderr)
            fputs("   With accessibility: \(a11yReport.elementsWithAccessibility)\n", stderr)
            fputs("   Coverage: \(String(format: "%.1f", a11yReport.accessibilityCoverage))%\n", stderr)
            fputs("   Issues: \(a11yReport.issues.count)\n", stderr)
            
            if !a11yReport.accessibilityUsage.isEmpty {
                fputs("\n📋 Accessibility APIs used:\n", stderr)
                for (api, count) in a11yReport.accessibilityUsage.sorted(by: { $0.value > $1.value }).prefix(5) {
                    fputs("     \(api): \(count) uses\n", stderr)
                }
            }
        }
        
        if accessibilityMode && !runAll {
            outputJSON(a11yReport, to: outputFile)
            return
        }
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
        if verbose {
            fputs("🧵 Running thread safety analysis...\n", stderr)
        }
        
        let threadAnalyzer = ThreadSafetyAnalyzer()
        let threadReport = threadAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Total issues: \(threadReport.totalIssues)\n", stderr)
            
            if !threadReport.issuesByType.isEmpty {
                fputs("\n🔍 Issues by type:\n", stderr)
                for (type, count) in threadReport.issuesByType.sorted(by: { $0.value > $1.value }) {
                    fputs("     \(type): \(count)\n", stderr)
                }
            }
            
            fputs("\n⚡ Concurrency patterns:\n", stderr)
            for (pattern, count) in threadReport.concurrencyPatterns.sorted(by: { $0.value > $1.value }).prefix(10) {
                fputs("     \(pattern): \(count)\n", stderr)
            }
            
            if !threadReport.recommendations.isEmpty {
                fputs("\n💡 Recommendations:\n", stderr)
                for rec in threadReport.recommendations {
                    fputs("     • \(rec)\n", stderr)
                }
            }
        }
        
        if threadingMode && !runAll {
            outputJSON(threadReport, to: outputFile)
            return
        }
    }
    
    // SwiftUI analysis
    if swiftuiMode || runAll {
        if verbose {
            fputs("🎨 Running SwiftUI analysis...\n", stderr)
        }
        
        let swiftUIAnalyzer = SwiftUIAnalyzer()
        let swiftUIReport = swiftUIAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   SwiftUI files: \(swiftUIReport.swiftUIFileCount)\n", stderr)
            fputs("   UIKit files: \(swiftUIReport.uiKitFileCount)\n", stderr)
            fputs("   Mixed files: \(swiftUIReport.mixedFiles)\n", stderr)
            fputs("   Views found: \(swiftUIReport.views.count)\n", stderr)
            
            fputs("\n📊 State management:\n", stderr)
            fputs("     @State: \(swiftUIReport.stateManagement.stateCount)\n", stderr)
            fputs("     @Binding: \(swiftUIReport.stateManagement.bindingCount)\n", stderr)
            fputs("     @ObservedObject: \(swiftUIReport.stateManagement.observedObjectCount)\n", stderr)
            fputs("     @StateObject: \(swiftUIReport.stateManagement.stateObjectCount)\n", stderr)
            fputs("     @EnvironmentObject: \(swiftUIReport.stateManagement.environmentObjectCount)\n", stderr)
            fputs("     @Published: \(swiftUIReport.stateManagement.publishedCount)\n", stderr)
            
            if !swiftUIReport.issues.isEmpty {
                fputs("\n⚠️ Issues: \(swiftUIReport.issues.count)\n", stderr)
            }
        }
        
        if swiftuiMode && !runAll {
            outputJSON(swiftUIReport, to: outputFile)
            return
        }
    }
    
    // UIKit analysis
    if uikitMode || runAll {
        if verbose {
            fputs("📱 Running UIKit analysis...\n", stderr)
        }
        
        let uikitAnalyzer = UIKitAnalyzer()
        let uikitReport = uikitAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   UIKit files: \(uikitReport.totalUIKitFiles)\n", stderr)
            fputs("   ViewControllers: \(uikitReport.viewControllers.count)\n", stderr)
            fputs("   Custom Views: \(uikitReport.views.count)\n", stderr)
            fputs("   Modernization score: \(uikitReport.modernizationScore)/100\n", stderr)
            
            fputs("\n📊 UIKit patterns:\n", stderr)
            fputs("     IBOutlets: \(uikitReport.patterns.ibOutlets)\n", stderr)
            fputs("     IBActions: \(uikitReport.patterns.ibActions)\n", stderr)
            fputs("     Auto Layout: \(uikitReport.patterns.autoLayoutConstraints)\n", stderr)
            fputs("     SnapKit: \(uikitReport.patterns.snapKitUsage)\n", stderr)
            fputs("     Frame-based: \(uikitReport.patterns.frameBasedLayout)\n", stderr)
            fputs("     TableViews: \(uikitReport.patterns.tableViewUsage)\n", stderr)
            fputs("     CollectionViews: \(uikitReport.patterns.collectionViewUsage)\n", stderr)
            
            fputs("\n🧭 Navigation:\n", stderr)
            fputs("     Storyboard instantiations: \(uikitReport.storyboardUsage.storyboardInstantiations)\n", stderr)
            fputs("     Segue usage: \(uikitReport.storyboardUsage.segueUsage)\n", stderr)
            fputs("     Programmatic navigation: \(uikitReport.storyboardUsage.programmaticNavigation)\n", stderr)
            
            if !uikitReport.issues.isEmpty {
                fputs("\n⚠️ Issues: \(uikitReport.issues.count)\n", stderr)
                for issue in uikitReport.issues.prefix(5) {
                    fputs("     \(issue.file): \(issue.description)\n", stderr)
                }
            }
        }
        
        if uikitMode && !runAll {
            outputJSON(uikitReport, to: outputFile)
            return
        }
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
        
        // Analyze from parent directory (where Podfile typically lives)
        let parentURL = rootURL.deletingLastPathComponent()
        let depAnalyzer = DependencyManagerAnalyzer()
        let depReport = depAnalyzer.analyze(projectRoot: parentURL)
        
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
        if verbose {
            fputs("💾 Running Core Data analysis...\n", stderr)
        }
        
        let coreDataAnalyzer = CoreDataAnalyzer()
        let coreDataReport = coreDataAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Has Core Data: \(coreDataReport.hasCoreData ? "Yes" : "No")\n", stderr)
            fputs("   Entities: \(coreDataReport.entities.count)\n", stderr)
            fputs("   Fetch requests: \(coreDataReport.patterns.fetchRequestCount)\n", stderr)
            
            if coreDataReport.hasCoreData {
                fputs("\n📊 Core Data patterns:\n", stderr)
                fputs("     Main context usage: \(coreDataReport.patterns.mainContextUsage)\n", stderr)
                fputs("     Background context usage: \(coreDataReport.patterns.backgroundContextUsage)\n", stderr)
                fputs("     Batch operations: \(coreDataReport.patterns.batchInsertCount + coreDataReport.patterns.batchDeleteCount)\n", stderr)
                fputs("     NSFetchedResultsController: \(coreDataReport.patterns.nsfetchedResultsControllerCount)\n", stderr)
                
                if !coreDataReport.issues.isEmpty {
                    fputs("\n⚠️ Issues: \(coreDataReport.issues.count)\n", stderr)
                }
            }
        }
        
        if coredataMode && !runAll {
            outputJSON(coreDataReport, to: outputFile)
            return
        }
    }
    
    // Documentation coverage analysis
    if docsMode || runAll {
        if verbose {
            fputs("📝 Running documentation analysis...\n", stderr)
        }
        
        let docsAnalyzer = DocumentationAnalyzer()
        let docsReport = docsAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Public symbols: \(docsReport.totalPublicSymbols)\n", stderr)
            fputs("   Documented: \(docsReport.documentedSymbols)\n", stderr)
            fputs("   Coverage: \(String(format: "%.1f", docsReport.coveragePercentage))%\n", stderr)
            
            fputs("\n📊 By type:\n", stderr)
            fputs("     Classes: \(docsReport.byType.classes.documented)/\(docsReport.byType.classes.total)\n", stderr)
            fputs("     Structs: \(docsReport.byType.structs.documented)/\(docsReport.byType.structs.total)\n", stderr)
            fputs("     Protocols: \(docsReport.byType.protocols.documented)/\(docsReport.byType.protocols.total)\n", stderr)
            fputs("     Functions: \(docsReport.byType.functions.documented)/\(docsReport.byType.functions.total)\n", stderr)
            
            if !docsReport.recommendations.isEmpty {
                fputs("\n💡 Recommendations:\n", stderr)
                for rec in docsReport.recommendations {
                    fputs("     • \(rec)\n", stderr)
                }
            }
        }
        
        if docsMode && !runAll {
            outputJSON(docsReport, to: outputFile)
            return
        }
    }
    
    // Retain cycle analysis
    if retainCyclesMode || runAll {
        if verbose {
            fputs("🔄 Running retain cycle analysis...\n", stderr)
        }
        
        let retainAnalyzer = RetainCycleAnalyzer()
        let retainReport = retainAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Risk score: \(retainReport.riskScore)/100\n", stderr)
            fputs("   Potential cycles: \(retainReport.potentialCycles.count)\n", stderr)
            fputs("   Delegate issues: \(retainReport.delegateIssues.count)\n", stderr)
            
            fputs("\n📊 Closure patterns:\n", stderr)
            fputs("     Closures with self: \(retainReport.patterns.closuresWithSelf)\n", stderr)
            fputs("     With [weak self]: \(retainReport.patterns.closuresWithWeakSelf)\n", stderr)
            fputs("     With [unowned self]: \(retainReport.patterns.closuresWithUnownedSelf)\n", stderr)
            fputs("     Strong delegates: \(retainReport.patterns.strongDelegates)\n", stderr)
            
            fputs("\n⏱️ Timer/Notification balance:\n", stderr)
            fputs("     Timers created: \(retainReport.patterns.timersCreated)\n", stderr)
            fputs("     Timers invalidated: \(retainReport.patterns.timersInvalidated)\n", stderr)
            fputs("     Notifications added: \(retainReport.patterns.notificationsAdded)\n", stderr)
            fputs("     Notifications removed: \(retainReport.patterns.notificationsRemoved)\n", stderr)
            
            if !retainReport.recommendations.isEmpty {
                fputs("\n💡 Recommendations:\n", stderr)
                for rec in retainReport.recommendations {
                    fputs("     • \(rec)\n", stderr)
                }
            }
        }
        
        if retainCyclesMode && !runAll {
            outputJSON(retainReport, to: outputFile)
            return
        }
    }
    
    // Refactoring analysis - god functions and extraction suggestions
    if refactorMode || runAll {
        if verbose {
            fputs("🔧 Running refactoring analysis...\n", stderr)
        }
        
        let refactorAnalyzer = RefactoringAnalyzer()
        let refactorReport = refactorAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   God functions found: \(refactorReport.godFunctions.count)\n", stderr)
            fputs("   Extraction opportunities: \(refactorReport.extractionOpportunities.count)\n", stderr)
            fputs("   Estimated complexity reduction: \(refactorReport.totalComplexityReduction)\n", stderr)
            
            if !refactorReport.godFunctions.isEmpty {
                fputs("\n🔥 God functions (by impact):\n", stderr)
                for godFunc in refactorReport.godFunctions.prefix(10) {
                    fputs("     \(godFunc.file):\(godFunc.name) - \(godFunc.lineCount) lines, complexity \(godFunc.complexity)\n", stderr)
                    for extraction in godFunc.extractableBlocks.prefix(3) {
                        fputs("       → Extract: \(extraction.suggestedName)() [lines \(extraction.startLine)-\(extraction.endLine)]\n", stderr)
                    }
                }
            }
            
            if !refactorReport.recommendations.isEmpty {
                fputs("\n💡 Recommendations:\n", stderr)
                for rec in refactorReport.recommendations {
                    fputs("     \(rec)\n", stderr)
                }
            }
        }
        
        if refactorMode && !runAll {
            outputJSON(refactorReport, to: outputFile)
            return
        }
    }
    
    // API surface analysis - full type signatures
    if apiMode || runAll {
        if verbose {
            fputs("📋 Running API surface analysis...\n", stderr)
        }
        
        let apiAnalyzer = APIAnalyzer()
        let apiReport = apiAnalyzer.analyze(files: swiftFiles, relativeTo: rootURL)
        
        if verbose {
            fputs("   Types: \(apiReport.types.count)\n", stderr)
            fputs("   Global functions: \(apiReport.globalFunctions.count)\n", stderr)
            fputs("   Public APIs: \(apiReport.totalPublicAPIs)\n", stderr)
            
            // Show analyzers specifically (useful for refactoring)
            let analyzers = apiReport.types.filter { $0.name.hasSuffix("Analyzer") }
            if !analyzers.isEmpty {
                fputs("\n🔧 Analyzer APIs:\n", stderr)
                for analyzer in analyzers.prefix(10) {
                    fputs("   \(analyzer.name):\n", stderr)
                    for method in analyzer.methods.filter({ $0.name == "analyze" }) {
                        let params = method.parameters.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
                        let ret = method.returnType ?? "Void"
                        fputs("     func \(method.name)(\(params)) -> \(ret)\n", stderr)
                    }
                }
            }
            
            // Show Report types (useful for understanding output)
            let reports = apiReport.types.filter { $0.name.hasSuffix("Report") }
            if !reports.isEmpty {
                fputs("\n📊 Report types (\(reports.count)):\n", stderr)
                for report in reports.prefix(10) {
                    let props = report.properties.map { $0.name }.prefix(5).joined(separator: ", ")
                    fputs("   \(report.name): \(props)...\n", stderr)
                }
            }
            
            if !apiReport.recommendations.isEmpty {
                fputs("\n💡 Recommendations:\n", stderr)
                for rec in apiReport.recommendations {
                    fputs("     • \(rec)\n", stderr)
                }
            }
        }
        
        if apiMode && !runAll {
            outputJSON(apiReport, to: outputFile)
            return
        }
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
