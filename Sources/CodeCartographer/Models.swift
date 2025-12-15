import Foundation

// MARK: - Output Models

public struct FileNode: Codable {
    public let path: String
    public var imports: [String]
    public var references: [SymbolReference]

    public init(path: String, imports: [String], references: [SymbolReference]) {
        self.path = path
        self.imports = imports
        self.references = references
    }
}

public struct SymbolReference: Codable {
    public enum Kind: String, Codable {
        case globalSingleton
        case propertyAccess
        case userDefaults
        case notificationCenter
        case awsCognito
        case keychain
        case other
    }

    public let kind: Kind
    public let symbol: String
    public let line: Int?
    public let context: String? // function/method name where reference occurs

    public init(kind: Kind, symbol: String, line: Int?, context: String?) {
        self.kind = kind
        self.symbol = symbol
        self.line = line
        self.context = context
    }
}

public struct AnalysisSummary: Codable {
    public var totalReferences: Int
    public var singletonUsage: [String: Int]  // symbol -> count
    public var hotspotFiles: [String]          // files with most references

    public init(totalReferences: Int, singletonUsage: [String: Int], hotspotFiles: [String]) {
        self.totalReferences = totalReferences
        self.singletonUsage = singletonUsage
        self.hotspotFiles = hotspotFiles
    }
}

// MARK: - Extended Analysis Result (with targets)

public struct ExtendedAnalysisResult: Codable {
    let analyzedAt: String
    let rootPath: String
    let fileCount: Int
    var files: [FileNode]
    var summary: AnalysisSummary
    var targets: TargetAnalysis?
}
