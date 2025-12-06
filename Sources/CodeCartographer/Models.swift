import Foundation

// MARK: - Output Models

struct FileNode: Codable {
    let path: String
    var imports: [String]
    var references: [SymbolReference]
}

struct SymbolReference: Codable {
    enum Kind: String, Codable {
        case globalSingleton
        case propertyAccess
        case userDefaults
        case notificationCenter
        case awsCognito
        case keychain
        case other
    }

    let kind: Kind
    let symbol: String
    let line: Int?
    let context: String? // function/method name where reference occurs
}

struct AnalysisResult: Codable {
    let analyzedAt: String
    let rootPath: String
    let fileCount: Int
    var files: [FileNode]
    var summary: AnalysisSummary
}

struct AnalysisSummary: Codable {
    var totalReferences: Int
    var singletonUsage: [String: Int]  // symbol -> count
    var hotspotFiles: [String]          // files with most references
}

// MARK: - Extended Analysis Result (with targets)

struct ExtendedAnalysisResult: Codable {
    let analyzedAt: String
    let rootPath: String
    let fileCount: Int
    var files: [FileNode]
    var summary: AnalysisSummary
    var targets: TargetAnalysis?
}
