import Foundation

// MARK: - Analysis Context

/// Shared context for all analysis runners
struct AnalysisContext {
    let files: [URL]
    let rootURL: URL
    let rootPath: String
    let verbose: Bool
    let outputFile: String?
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
                fputs("     \(endpoint.method) \(endpoint.endpoint)\n", stderr)
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
    }
    
    let refactorAnalyzer = RefactoringAnalyzer()
    let refactorReport = refactorAnalyzer.analyze(files: ctx.files, relativeTo: ctx.rootURL)
    
    if ctx.verbose {
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
