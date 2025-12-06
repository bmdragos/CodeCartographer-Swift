import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Analysis Context

/// Shared context for all analysis runners
struct AnalysisContext {
    let files: [URL]
    let rootURL: URL
    let rootPath: String
    let verbose: Bool
    let outputFile: String?
    
    // Optional dependencies for complex analyses
    var typeMap: TypeMap?
    var targetFiles: Set<String>?
    var parentURL: URL?
    var targetAnalysis: TargetAnalysis?
    var projectPath: String?
    
    // Refactor mode options
    var refactorRemainingOnly: Bool = false  // Only show blocks > 15 lines
}

// MARK: - Analysis Runners
// Each returns true if main() should exit (i.e., it was the specific mode requested)

func runSmellsAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🦨 Running code smell analysis...\n", stderr)
    }
    
    let smellAnalyzer = CodeSmellAnalyzer()
    let smellReport = smellAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
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
    
    if isSpecificMode && !runAll {
        outputJSON(smellReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runFunctionsAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("📏 Running function metrics analysis...\n", stderr)
    }
    
    let funcAnalyzer = FunctionMetricsAnalyzer()
    let funcReport = funcAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Total functions: \(funcReport.totalFunctions)\n", stderr)
        fputs("   Average line count: \(String(format: "%.1f", funcReport.averageLineCount))\n", stderr)
        fputs("   Average complexity: \(String(format: "%.1f", funcReport.averageComplexity))\n", stderr)
        fputs("   God functions (>50 lines or complexity >10): \(funcReport.godFunctions.count)\n", stderr)
        
        if !funcReport.godFunctions.isEmpty {
            fputs("\n⚠️ Top god functions:\n", stderr)
            for gf in funcReport.godFunctions.prefix(10) {
                fputs("     \(gf.name) in \(gf.file): \(gf.lineCount) lines, complexity \(gf.complexity)\n", stderr)
            }
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(funcReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runTechDebtAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("📝 Running tech debt analysis...\n", stderr)
    }
    
    let debtAnalyzer = TechDebtAnalyzer()
    let debtReport = debtAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Total markers: \(debtReport.totalMarkers)\n", stderr)
        fputs("   By type:\n", stderr)
        for (type, count) in debtReport.markersByType.sorted(by: { $0.value > $1.value }) {
            fputs("     \(type): \(count)\n", stderr)
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(debtReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runAuthMigrationAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🔐 Running auth migration analysis...\n", stderr)
    }
    
    let authAnalyzer = AuthMigrationAnalyzer()
    let authReport = authAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Total auth accesses: \(authReport.totalAccesses)\n", stderr)
        fputs("   Properties tracked: \(authReport.accessesByProperty.count)\n", stderr)
        
        if !authReport.accessesByProperty.isEmpty {
            fputs("\n📊 Top accessed properties:\n", stderr)
            for (prop, count) in authReport.accessesByProperty.sorted(by: { $0.value > $1.value }).prefix(10) {
                fputs("     \(prop): \(count) accesses\n", stderr)
            }
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(authReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runTypesAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("📐 Running type definition analysis...\n", stderr)
    }
    
    let depAnalyzer = DependencyGraphAnalyzer()
    let typeMap = depAnalyzer.analyzeTypes(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Types defined: \(typeMap.definitions.count)\n", stderr)
        fputs("   Protocols: \(typeMap.definitions.filter { $0.kind == .protocol }.count)\n", stderr)
        fputs("   Classes: \(typeMap.definitions.filter { $0.kind == .class }.count)\n", stderr)
        fputs("   Structs: \(typeMap.definitions.filter { $0.kind == .struct }.count)\n", stderr)
        
        let topProtocols = typeMap.protocolConformances.sorted { $0.value.count > $1.value.count }.prefix(5)
        if !topProtocols.isEmpty {
            fputs("\n📋 Most implemented protocols:\n", stderr)
            for (proto, conformers) in topProtocols {
                fputs("   \(proto): \(conformers.count) conformers\n", stderr)
            }
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(typeMap, to: ctx.outputFile)
        return true
    }
    return false
}

func runDelegatesAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🔗 Running delegate wiring analysis...\n", stderr)
    }
    
    // Need typeMap - either passed in or create it
    let typeMap: TypeMap
    if let existing = ctx.typeMap {
        typeMap = existing
    } else {
        let depAnalyzer = DependencyGraphAnalyzer()
        typeMap = depAnalyzer.analyzeTypes(files: ctx.files, relativeTo: ctx.rootURL)
    }
    
    let delegateAnalyzer = DelegateAnalyzer()
    let delegateReport = delegateAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL, typeMap: typeMap)
    
    if ctx.verbose {
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
    
    if isSpecificMode && !runAll {
        outputJSON(delegateReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runUnusedAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🗑️  Running unused code analysis...\n", stderr)
    }
    
    let unusedAnalyzer = UnusedCodeAnalyzer()
    let unusedReport = unusedAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL, targetFiles: ctx.targetFiles)
    
    if ctx.verbose {
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
    
    if isSpecificMode && !runAll {
        outputJSON(unusedReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runNetworkAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🌐 Running network analysis...\n", stderr)
    }
    
    let networkAnalyzer = NetworkAnalyzer()
    let networkReport = networkAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Total endpoints found: \(networkReport.endpoints.count)\n", stderr)
        fputs("   Files with network code: \(networkReport.filesByNetworkUsage.count)\n", stderr)
        
        if !networkReport.endpoints.isEmpty {
            fputs("\n🔗 Endpoints:\n", stderr)
            for endpoint in networkReport.endpoints.prefix(10) {
                let method = endpoint.method ?? "?"
                let path = endpoint.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                fputs("     [\(method)] \(path)\n", stderr)
            }
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(networkReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runReactiveAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("⚡ Running reactive analysis...\n", stderr)
    }
    
    let reactiveAnalyzer = ReactiveAnalyzer()
    let reactiveReport = reactiveAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Framework: \(reactiveReport.framework)\n", stderr)
        fputs("   Total subscriptions: \(reactiveReport.totalSubscriptions)\n", stderr)
        fputs("   DisposeBags: \(reactiveReport.totalDisposeBags)\n", stderr)
        fputs("   Potential leaks: \(reactiveReport.potentialLeaks.count)\n", stderr)
    }
    
    if isSpecificMode && !runAll {
        outputJSON(reactiveReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runViewControllersAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("📱 Running ViewController analysis...\n", stderr)
    }
    
    let vcAnalyzer = ViewControllerAnalyzer()
    let vcReport = vcAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Total ViewControllers: \(vcReport.viewControllers.count)\n", stderr)
        fputs("   Issues: \(vcReport.issues.count)\n", stderr)
        fputs("   Heavy lifecycle methods: \(vcReport.heavyLifecycleMethods.count)\n", stderr)
    }
    
    if isSpecificMode && !runAll {
        outputJSON(vcReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runLocalizationAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🌍 Running localization analysis...\n", stderr)
    }
    
    let locAnalyzer = LocalizationAnalyzer()
    let locReport = locAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Total strings: \(locReport.hardcodedStrings + locReport.localizedStrings)\n", stderr)
        fputs("   Localized: \(locReport.localizedStrings)\n", stderr)
        fputs("   Hardcoded: \(locReport.hardcodedStrings)\n", stderr)
        fputs("   Coverage: \(String(format: "%.1f", locReport.localizationCoverage))%\n", stderr)
    }
    
    if isSpecificMode && !runAll {
        outputJSON(locReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runAccessibilityAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("♿ Running accessibility analysis...\n", stderr)
    }
    
    let a11yAnalyzer = AccessibilityAnalyzer()
    let a11yReport = a11yAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   UI elements: \(a11yReport.totalUIElements)\n", stderr)
        fputs("   With accessibility: \(a11yReport.elementsWithAccessibility)\n", stderr)
        fputs("   Coverage: \(String(format: "%.1f", a11yReport.accessibilityCoverage))%\n", stderr)
        
        if !a11yReport.accessibilityUsage.isEmpty {
            fputs("\n📊 Accessibility API usage:\n", stderr)
            for (api, count) in a11yReport.accessibilityUsage.sorted(by: { $0.value > $1.value }).prefix(5) {
                fputs("     \(api): \(count) uses\n", stderr)
            }
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(a11yReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runThreadingAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🧵 Running thread safety analysis...\n", stderr)
    }
    
    let threadAnalyzer = ThreadSafetyAnalyzer()
    let threadReport = threadAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Issues: \(threadReport.totalIssues)\n", stderr)
        
        if !threadReport.concurrencyPatterns.isEmpty {
            fputs("\n⚡ Concurrency patterns:\n", stderr)
            for (pattern, count) in threadReport.concurrencyPatterns.sorted(by: { $0.value > $1.value }).prefix(10) {
                fputs("     \(pattern): \(count)\n", stderr)
            }
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(threadReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runSwiftUIAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🎨 Running SwiftUI analysis...\n", stderr)
    }
    
    let swiftUIAnalyzer = SwiftUIAnalyzer()
    let swiftUIReport = swiftUIAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   SwiftUI files: \(swiftUIReport.swiftUIFileCount)\n", stderr)
        fputs("   UIKit files: \(swiftUIReport.uiKitFileCount)\n", stderr)
        fputs("   Views found: \(swiftUIReport.views.count)\n", stderr)
        
        fputs("\n📊 State management:\n", stderr)
        fputs("     @State: \(swiftUIReport.stateManagement.stateCount)\n", stderr)
        fputs("     @Binding: \(swiftUIReport.stateManagement.bindingCount)\n", stderr)
        fputs("     @ObservedObject: \(swiftUIReport.stateManagement.observedObjectCount)\n", stderr)
        fputs("     @StateObject: \(swiftUIReport.stateManagement.stateObjectCount)\n", stderr)
    }
    
    if isSpecificMode && !runAll {
        outputJSON(swiftUIReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runUIKitAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("📱 Running UIKit analysis...\n", stderr)
    }
    
    let uikitAnalyzer = UIKitAnalyzer()
    let uikitReport = uikitAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   UIKit files: \(uikitReport.totalUIKitFiles)\n", stderr)
        fputs("   ViewControllers: \(uikitReport.viewControllers.count)\n", stderr)
        fputs("   Views: \(uikitReport.views.count)\n", stderr)
        fputs("   Modernization score: \(uikitReport.modernizationScore)/100\n", stderr)
        
        fputs("\n📊 UIKit patterns:\n", stderr)
        fputs("     IBOutlets: \(uikitReport.patterns.ibOutlets)\n", stderr)
        fputs("     IBActions: \(uikitReport.patterns.ibActions)\n", stderr)
        fputs("     AutoLayout: \(uikitReport.patterns.autoLayoutConstraints)\n", stderr)
        fputs("     Delegates: \(uikitReport.patterns.delegatePatterns)\n", stderr)
    }
    
    if isSpecificMode && !runAll {
        outputJSON(uikitReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runCoreDataAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("💾 Running Core Data analysis...\n", stderr)
    }
    
    let coreDataAnalyzer = CoreDataAnalyzer()
    let coreDataReport = coreDataAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Has Core Data: \(coreDataReport.hasCoreData ? "Yes" : "No")\n", stderr)
        fputs("   Entities: \(coreDataReport.entities.count)\n", stderr)
        fputs("   Fetch requests: \(coreDataReport.patterns.fetchRequestCount)\n", stderr)
        
        if coreDataReport.hasCoreData {
            fputs("\n📊 Core Data patterns:\n", stderr)
            fputs("     Main context usage: \(coreDataReport.patterns.mainContextUsage)\n", stderr)
            fputs("     Background context usage: \(coreDataReport.patterns.backgroundContextUsage)\n", stderr)
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(coreDataReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runDocsAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("📝 Running documentation analysis...\n", stderr)
    }
    
    let docsAnalyzer = DocumentationAnalyzer()
    let docsReport = docsAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Public symbols: \(docsReport.totalPublicSymbols)\n", stderr)
        fputs("   Documented: \(docsReport.documentedSymbols)\n", stderr)
        fputs("   Coverage: \(String(format: "%.1f", docsReport.coveragePercentage))%\n", stderr)
    }
    
    if isSpecificMode && !runAll {
        outputJSON(docsReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runRetainCyclesAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🔄 Running retain cycle analysis...\n", stderr)
    }
    
    let retainAnalyzer = RetainCycleAnalyzer()
    let retainReport = retainAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Risk score: \(retainReport.riskScore)/100\n", stderr)
        fputs("   Potential cycles: \(retainReport.potentialCycles.count)\n", stderr)
        fputs("   Delegate issues: \(retainReport.delegateIssues.count)\n", stderr)
        
        fputs("\n📊 Closure patterns:\n", stderr)
        fputs("     Closures with self: \(retainReport.patterns.closuresWithSelf)\n", stderr)
        fputs("     With [weak self]: \(retainReport.patterns.closuresWithWeakSelf)\n", stderr)
    }
    
    if isSpecificMode && !runAll {
        outputJSON(retainReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runRefactoringAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🔧 Running refactoring analysis...\n", stderr)
        if ctx.refactorRemainingOnly {
            fputs("   (--remaining: only showing blocks > 15 lines)\n", stderr)
        }
    }
    
    let refactorAnalyzer = RefactoringAnalyzer()
    var refactorReport = refactorAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    // Filter to only remaining large blocks if requested
    if ctx.refactorRemainingOnly {
        var filteredReport = refactorReport
        filteredReport.godFunctions = refactorReport.godFunctions.map { gf in
            var filtered = gf
            filtered.extractableBlocks = gf.extractableBlocks.filter { $0.lineCount > 15 }
            return filtered
        }.filter { !$0.extractableBlocks.isEmpty }
        filteredReport.extractionOpportunities = refactorReport.extractionOpportunities.map { opp in
            var filtered = opp
            filtered.suggestedExtractions = opp.suggestedExtractions.filter { $0.lineCount > 15 }
            return filtered
        }.filter { !$0.suggestedExtractions.isEmpty }
        refactorReport = filteredReport
    }
    
    if ctx.verbose {
        fputs("   God functions found: \(refactorReport.godFunctions.count)\n", stderr)
        fputs("   Extraction opportunities: \(refactorReport.extractionOpportunities.count)\n", stderr)
        fputs("   Estimated complexity reduction: \(refactorReport.totalComplexityReduction)\n", stderr)
        
        if !refactorReport.godFunctions.isEmpty {
            fputs("\n🔥 God functions (by impact):\n", stderr)
            for godFunc in refactorReport.godFunctions.prefix(5) {
                fputs("     \(godFunc.file):\(godFunc.name) - \(godFunc.lineCount) lines, complexity \(godFunc.complexity)\n", stderr)
                for extraction in godFunc.extractableBlocks.prefix(5) {
                    let diffIcon = extraction.extractionDifficulty == .hard ? "⚠️" : (extraction.extractionDifficulty == .medium ? "📦" : "✅")
                    fputs("       \(diffIcon) \(extraction.suggestedName)() [lines \(extraction.startLine)-\(extraction.endLine)] [\(extraction.extractionDifficulty.rawValue)]\n", stderr)
                    
                    // Show analyzer usage with full API context
                    for analyzer in extraction.usedAnalyzers {
                        let ret = analyzer.returnType ?? "?"
                        if let sig = analyzer.signature {
                            fputs("          API: \(analyzer.analyzerType).\(sig) -> \(ret)\n", stderr)
                        } else {
                            fputs("          Uses: \(analyzer.analyzerType).\(analyzer.methodCalled)() -> \(ret)\n", stderr)
                        }
                        if let props = analyzer.keyProperties, !props.isEmpty {
                            fputs("          Props: \(props.joined(separator: ", "))\n", stderr)
                        }
                    }
                    
                    // Show special dependencies
                    for dep in extraction.specialDependencies {
                        fputs("          ⚠️ Needs: \(dep)\n", stderr)
                    }
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
    
    if isSpecificMode && !runAll {
        outputJSON(refactorReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runAPIAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("📋 Running API surface analysis...\n", stderr)
    }
    
    let apiAnalyzer = APIAnalyzer()
    let apiReport = apiAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
        fputs("   Types: \(apiReport.types.count)\n", stderr)
        fputs("   Global functions: \(apiReport.globalFunctions.count)\n", stderr)
        fputs("   Public APIs: \(apiReport.totalPublicAPIs)\n", stderr)
        
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
    }
    
    if isSpecificMode && !runAll {
        outputJSON(apiReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runTestsAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
        fputs("🧪 Running test coverage analysis...\n", stderr)
    }
    
    // For test coverage, scan parent directory to find sibling test folders
    let parentURL = ctx.parentURL ?? ctx.rootURL.deletingLastPathComponent()
    let allFilesIncludingTests = findAllSwiftFiles(in: parentURL)
    
    if ctx.verbose {
        fputs("   Scanning parent directory for tests: \(parentURL.path)\n", stderr)
        fputs("   Found \(allFilesIncludingTests.count) total Swift files (including tests)\n", stderr)
    }
    
    // Use existing target analysis or try to find xcodeproj in parent directory
    var parentTargetAnalysis: TargetAnalysis? = ctx.targetAnalysis
    if parentTargetAnalysis == nil && ctx.projectPath == nil {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: parentURL.path) {
            for item in contents {
                if item.hasSuffix(".xcodeproj") {
                    let projPath = parentURL.appendingPathComponent(item).appendingPathComponent("project.pbxproj").path
                    if ctx.verbose {
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
    
    if ctx.verbose {
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
    
    if isSpecificMode && !runAll {
        outputJSON(testReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runDepsAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    if ctx.verbose {
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
    
    let projectRoot = findProjectRoot(from: ctx.rootURL)
    let depAnalyzer = DependencyManagerAnalyzer()
    let depReport = depAnalyzer.analyze(projectRoot: projectRoot)
    
    if ctx.verbose {
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
    
    if isSpecificMode && !runAll {
        outputJSON(depReport, to: ctx.outputFile)
        return true
    }
    return false
}

func runSingletonsAnalysis(ctx: AnalysisContext, isSpecificMode: Bool, runAll: Bool) -> Bool {
    var nodes: [FileNode] = []
    
    if ctx.verbose {
        fputs("📊 Running singleton analysis...\n", stderr)
    }
    
    for (index, fileURL) in ctx.files.enumerated() {
        if ctx.verbose && index % 100 == 0 && index > 0 {
            fputs("   Analyzing... \(index)/\(ctx.files.count)\n", stderr)
        }
        
        if let node = analyzeSingletonFile(at: fileURL, relativeTo: ctx.rootURL) {
            if !node.references.isEmpty || !node.imports.isEmpty {
                nodes.append(node)
            }
        }
    }
    
    let summary = buildSingletonSummary(from: nodes)
    
    let dateFormatter = ISO8601DateFormatter()
    let result = ExtendedAnalysisResult(
        analyzedAt: dateFormatter.string(from: Date()),
        rootPath: ctx.rootPath,
        fileCount: ctx.files.count,
        files: nodes.sorted { $0.references.count > $1.references.count },
        summary: summary,
        targets: ctx.targetAnalysis
    )
    
    if ctx.verbose {
        fputs("\n📈 Summary:\n", stderr)
        fputs("   Total files analyzed: \(ctx.files.count)\n", stderr)
        fputs("   Files with references: \(nodes.count)\n", stderr)
        fputs("   Total references: \(summary.totalReferences)\n", stderr)
        fputs("\n🔥 Top singletons:\n", stderr)
        for (symbol, count) in summary.singletonUsage.sorted(by: { $0.value > $1.value }).prefix(10) {
            fputs("   \(count)x \(symbol)\n", stderr)
        }
    }
    
    if isSpecificMode && !runAll {
        outputJSON(result, to: ctx.outputFile)
        return true
    }
    return false
}

// Helper functions for singleton analysis
private func analyzeSingletonFile(at url: URL, relativeTo root: URL) -> FileNode? {
    guard let sourceText = try? String(contentsOf: url) else {
        fputs("⚠️ Failed to read \(url.path)\n", stderr)
        return nil
    }
    
    let tree = Parser.parse(source: sourceText)
    let analyzer = FileAnalyzer(filePath: url.path, sourceText: sourceText)
    analyzer.walk(tree)
    
    let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
    
    return FileNode(
        path: relativePath,
        imports: Array(analyzer.imports).sorted(),
        references: analyzer.references
    )
}

private func buildSingletonSummary(from files: [FileNode]) -> AnalysisSummary {
    var singletonUsage: [String: Int] = [:]
    var fileRefCounts: [(String, Int)] = []
    
    for file in files {
        fileRefCounts.append((file.path, file.references.count))
        
        for ref in file.references {
            let symbol = ref.symbol
            if let range = symbol.range(of: ".sharedInstance") {
                let base = String(symbol[..<range.lowerBound]) + ".sharedInstance()"
                singletonUsage[base, default: 0] += 1
            } else {
                singletonUsage[symbol, default: 0] += 1
            }
        }
    }
    
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
