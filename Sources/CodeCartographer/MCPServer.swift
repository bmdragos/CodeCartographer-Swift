import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: JSONValue?
}

struct JSONRPCResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCId
    let result: JSONValue?
    let error: JSONRPCError?
    
    init(id: JSONRPCId, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }
    
    init(id: JSONRPCId, error: JSONRPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: JSONValue?
    
    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
    
    static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    static let internalError = JSONRPCError(code: -32603, message: "Internal error")
}

// MARK: - JSON Value (for dynamic JSON handling)

enum JSONRPCId: Codable, Equatable {
    case int(Int)
    case string(String)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(JSONRPCId.self, .init(codingPath: [], debugDescription: "Expected Int or String"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: [], debugDescription: "Unknown JSON type"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
    
    // Helper accessors
    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    
    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }
    
    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    
    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    
    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    
    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self {
            return dict[key]
        }
        return nil
    }
    
    // Create from Encodable
    static func from<T: Encodable>(_ value: T) -> JSONValue? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return json
    }
}

// MARK: - MCP Tool Definition

struct MCPTool: Codable {
    let name: String
    let description: String
    let inputSchema: MCPInputSchema
}

struct MCPInputSchema: Codable {
    let type: String
    let properties: [String: MCPProperty]
    let required: [String]?
    
    init(properties: [String: MCPProperty] = [:], required: [String]? = nil) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct MCPProperty: Codable {
    let type: String
    let description: String
    let `enum`: [String]?
    
    init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.`enum` = enumValues
    }
}

// MARK: - Project Cache

struct CachedFile {
    let path: String
    let relativePath: String
    var contentHash: String
    var ast: SourceFileSyntax?
    var sourceText: String
    var lastModified: Date
    var analysisCache: [String: Data]  // analyzer name -> cached JSON result
    
    mutating func invalidate() {
        ast = nil
        analysisCache.removeAll()
    }
}

class ProjectCache {
    let projectRoot: URL
    private(set) var files: [String: CachedFile] = [:]  // relative path -> cached file
    private(set) var swiftFileURLs: [URL] = []
    private(set) var lastScanTime: Date?
    
    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }
    
    /// Scan for Swift files and build initial cache structure
    func scan(verbose: Bool = false) {
        let startTime = Date()
        swiftFileURLs = findSwiftFiles(in: projectRoot)
        
        if verbose {
            fputs("[MCP] Scanned \(swiftFileURLs.count) Swift files in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s\n", stderr)
        }
        
        // Build cache entries (but don't parse yet - lazy parsing)
        for url in swiftFileURLs {
            let relativePath = url.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
            
            // Check if file changed
            if let existing = files[relativePath] {
                if let hash = hashFile(url), hash == existing.contentHash {
                    continue  // File unchanged, keep cache
                }
            }
            
            // Create new cache entry (lazy - don't parse AST yet)
            if let sourceText = try? String(contentsOf: url),
               let hash = hashFile(url) {
                files[relativePath] = CachedFile(
                    path: url.path,
                    relativePath: relativePath,
                    contentHash: hash,
                    ast: nil,
                    sourceText: sourceText,
                    lastModified: Date(),
                    analysisCache: [:]
                )
            }
        }
        
        lastScanTime = Date()
    }
    
    /// Get or parse AST for a file
    func getAST(for relativePath: String) -> SourceFileSyntax? {
        guard var cached = files[relativePath] else { return nil }
        
        if cached.ast == nil {
            cached.ast = Parser.parse(source: cached.sourceText)
            files[relativePath] = cached
        }
        
        return cached.ast
    }
    
    /// Get source text for a file
    func getSourceText(for relativePath: String) -> String? {
        return files[relativePath]?.sourceText
    }
    
    /// Invalidate a specific file
    func invalidate(path: String) {
        // Try both absolute and relative paths
        if files[path] != nil {
            files[path]?.invalidate()
        } else {
            let relativePath = path.replacingOccurrences(of: projectRoot.path + "/", with: "")
            files[relativePath]?.invalidate()
        }
    }
    
    /// Invalidate all cached data
    func invalidateAll() {
        for key in files.keys {
            files[key]?.invalidate()
        }
    }
    
    /// Get cached analysis result or nil
    func getCachedAnalysis<T: Decodable>(for relativePath: String, analyzer: String, as type: T.Type) -> T? {
        guard let cached = files[relativePath],
              let data = cached.analysisCache[analyzer],
              let result = try? JSONDecoder().decode(type, from: data) else {
            return nil
        }
        return result
    }
    
    /// Store analysis result in cache
    func cacheAnalysis<T: Encodable>(for relativePath: String, analyzer: String, result: T) {
        guard files[relativePath] != nil,
              let data = try? JSONEncoder().encode(result) else {
            return
        }
        files[relativePath]?.analysisCache[analyzer] = data
    }
    
    private func hashFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Simple hash using the data's hash value (fast but not cryptographic)
        // For a real implementation, use SHA256
        return String(data.hashValue, radix: 16)
    }
}

// MARK: - MCP Server

class MCPServer {
    let projectRoot: URL
    let cache: ProjectCache
    let verbose: Bool
    
    private var isInitialized = false
    
    init(projectRoot: URL, verbose: Bool = false) {
        self.projectRoot = projectRoot
        self.cache = ProjectCache(projectRoot: projectRoot)
        self.verbose = verbose
    }
    
    /// Main server loop - reads from stdin, writes to stdout
    func run() {
        if verbose {
            fputs("[MCP] CodeCartographer MCP Server starting...\n", stderr)
            fputs("[MCP] Project root: \(projectRoot.path)\n", stderr)
        }
        
        // Initial scan
        cache.scan(verbose: verbose)
        
        if verbose {
            fputs("[MCP] Ready. Listening for JSON-RPC messages on stdin...\n", stderr)
        }
        
        // Read loop
        while let line = readLine() {
            if line.isEmpty { continue }
            handleMessage(line)
        }
        
        if verbose {
            fputs("[MCP] Server shutting down.\n", stderr)
        }
    }
    
    private func handleMessage(_ jsonString: String) {
        if verbose {
            fputs("[MCP] <- \(jsonString.prefix(200))\(jsonString.count > 200 ? "..." : "")\n", stderr)
        }
        
        guard let data = jsonString.data(using: .utf8),
              let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else {
            sendError(id: .int(0), error: .parseError)
            return
        }
        
        // Route the method
        switch request.method {
        case "initialize":
            handleInitialize(request)
        case "initialized":
            // Notification, no response needed
            if verbose { fputs("[MCP] Client initialized\n", stderr) }
        case "tools/list":
            handleListTools(request)
        case "tools/call":
            handleCallTool(request)
        case "ping":
            if let id = request.id {
                sendResult(id: id, result: .object([:]))
            }
        default:
            // Unknown method
            if let id = request.id {
                sendError(id: id, error: .methodNotFound)
            }
        }
    }
    
    // MARK: - Protocol Handlers
    
    private func handleInitialize(_ request: JSONRPCRequest) {
        guard let id = request.id else { return }
        
        isInitialized = true
        
        let result: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string("CodeCartographer"),
                "version": .string("1.0.0")
            ])
        ])
        
        sendResult(id: id, result: result)
    }
    
    private func handleListTools(_ request: JSONRPCRequest) {
        guard let id = request.id else { return }
        
        let tools: [MCPTool] = [
            MCPTool(
                name: "get_summary",
                description: "Get a quick health summary of the Swift project including code smells, god functions, and refactoring opportunities",
                inputSchema: MCPInputSchema()
            ),
            MCPTool(
                name: "analyze_file",
                description: "Get detailed health analysis for a single Swift file",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Path to the Swift file (relative or filename)")
                    ],
                    required: ["path"]
                )
            ),
            MCPTool(
                name: "find_smells",
                description: "Find code smells (force unwraps, magic numbers, etc.) in the project or a specific file",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze (analyzes whole project if omitted)")
                    ]
                )
            ),
            MCPTool(
                name: "find_god_functions",
                description: "Find large/complex functions that may need refactoring",
                inputSchema: MCPInputSchema(
                    properties: [
                        "minLines": MCPProperty(type: "integer", description: "Minimum line count (default: 50)"),
                        "minComplexity": MCPProperty(type: "integer", description: "Minimum cyclomatic complexity (default: 10)")
                    ]
                )
            ),
            MCPTool(
                name: "check_impact",
                description: "Analyze the blast radius of changing a symbol (class, function, property)",
                inputSchema: MCPInputSchema(
                    properties: [
                        "symbol": MCPProperty(type: "string", description: "The symbol name to analyze (e.g., 'AuthManager', 'fetchUser')")
                    ],
                    required: ["symbol"]
                )
            ),
            MCPTool(
                name: "suggest_refactoring",
                description: "Get extraction suggestions for god functions",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "track_property",
                description: "Find all accesses to a property pattern (e.g., 'AuthManager.shared', 'account.*')",
                inputSchema: MCPInputSchema(
                    properties: [
                        "pattern": MCPProperty(type: "string", description: "Property pattern to track (supports wildcards)")
                    ],
                    required: ["pattern"]
                )
            ),
            MCPTool(
                name: "find_calls",
                description: "Find method calls matching a pattern (e.g., '*.forgotPassword', 'api.*')",
                inputSchema: MCPInputSchema(
                    properties: [
                        "pattern": MCPProperty(type: "string", description: "Method call pattern to find")
                    ],
                    required: ["pattern"]
                )
            ),
            MCPTool(
                name: "list_files",
                description: "List Swift files in the project",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: filter to files containing this path")
                    ]
                )
            ),
            MCPTool(
                name: "read_source",
                description: "Read source code from a file",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Path to the Swift file"),
                        "startLine": MCPProperty(type: "integer", description: "Optional: start line (1-indexed)"),
                        "endLine": MCPProperty(type: "integer", description: "Optional: end line (1-indexed)")
                    ],
                    required: ["path"]
                )
            ),
            MCPTool(
                name: "invalidate_cache",
                description: "Clear cached analysis results to force re-analysis",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to invalidate (invalidates all if omitted)")
                    ]
                )
            ),
            MCPTool(
                name: "rescan_project",
                description: "Rescan project for new/deleted files",
                inputSchema: MCPInputSchema()
            )
        ]
        
        let toolsJson: [JSONValue] = tools.compactMap { JSONValue.from($0) }
        let result: JSONValue = .object(["tools": .array(toolsJson)])
        
        sendResult(id: id, result: result)
    }
    
    private func handleCallTool(_ request: JSONRPCRequest) {
        guard let id = request.id else { return }
        
        guard let params = request.params?.objectValue,
              let toolName = params["name"]?.stringValue else {
            sendError(id: id, error: .invalidParams)
            return
        }
        
        let arguments = params["arguments"]?.objectValue ?? [:]
        
        if verbose {
            fputs("[MCP] Calling tool: \(toolName)\n", stderr)
        }
        
        do {
            let result = try executeTool(name: toolName, arguments: arguments)
            sendToolResult(id: id, result: result)
        } catch {
            sendError(id: id, error: JSONRPCError(code: -32000, message: error.localizedDescription))
        }
    }
    
    // MARK: - Tool Execution
    
    private func executeTool(name: String, arguments: [String: JSONValue]) throws -> String {
        switch name {
        case "get_summary":
            return try executeGetSummary()
        case "analyze_file":
            guard let path = arguments["path"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: path"])
            }
            return try executeAnalyzeFile(path: path)
        case "find_smells":
            let path = arguments["path"]?.stringValue
            return try executeFindSmells(path: path)
        case "find_god_functions":
            let minLines = arguments["minLines"]?.intValue ?? 50
            let minComplexity = arguments["minComplexity"]?.intValue ?? 10
            return try executeFindGodFunctions(minLines: minLines, minComplexity: minComplexity)
        case "check_impact":
            guard let symbol = arguments["symbol"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: symbol"])
            }
            return try executeCheckImpact(symbol: symbol)
        case "suggest_refactoring":
            let path = arguments["path"]?.stringValue
            return try executeSuggestRefactoring(path: path)
        case "track_property":
            guard let pattern = arguments["pattern"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: pattern"])
            }
            return try executeTrackProperty(pattern: pattern)
        case "find_calls":
            guard let pattern = arguments["pattern"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: pattern"])
            }
            return try executeFindCalls(pattern: pattern)
        case "list_files":
            let path = arguments["path"]?.stringValue
            return try executeListFiles(path: path)
        case "read_source":
            guard let path = arguments["path"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: path"])
            }
            let startLine = arguments["startLine"]?.intValue
            let endLine = arguments["endLine"]?.intValue
            return try executeReadSource(path: path, startLine: startLine, endLine: endLine)
        case "invalidate_cache":
            let path = arguments["path"]?.stringValue
            return executeInvalidateCache(path: path)
        case "rescan_project":
            return executeRescanProject()
        default:
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }
    
    // MARK: - Tool Implementations
    
    private func executeGetSummary() throws -> String {
        let files = cache.swiftFileURLs
        
        let smellAnalyzer = CodeSmellAnalyzer()
        let smellReport = smellAnalyzer.analyze(files: files, relativeTo: projectRoot)
        
        let metricsAnalyzer = FunctionMetricsAnalyzer()
        let metricsReport = metricsAnalyzer.analyze(files: files, relativeTo: projectRoot)
        
        let refactorAnalyzer = RefactoringAnalyzer()
        let refactorReport = refactorAnalyzer.analyze(files: files, relativeTo: projectRoot)
        
        let retainAnalyzer = RetainCycleAnalyzer()
        let retainReport = retainAnalyzer.analyze(files: files, relativeTo: projectRoot)
        
        struct Summary: Codable {
            let analyzedAt: String
            let fileCount: Int
            let totalSmells: Int
            let smellsByType: [String: Int]
            let totalFunctions: Int
            let godFunctions: Int
            let averageComplexity: Double
            let retainCycleRisk: Int
            let extractionOpportunities: Int
            let topGodFunctions: [GodFunctionBrief]
            let topIssues: [String]
        }
        
        struct GodFunctionBrief: Codable {
            let name: String
            let file: String
            let lines: Int
            let complexity: Int
        }
        
        let topGodFuncs = metricsReport.godFunctions.prefix(5).map {
            GodFunctionBrief(name: $0.name, file: $0.file, lines: $0.lineCount, complexity: $0.complexity)
        }
        
        var issues: [String] = []
        if metricsReport.godFunctions.count > 0 {
            issues.append("\(metricsReport.godFunctions.count) god functions need refactoring")
        }
        if smellReport.totalSmells > 50 {
            issues.append("\(smellReport.totalSmells) code smells detected")
        }
        if retainReport.riskScore > 50 {
            issues.append("High retain cycle risk: \(retainReport.riskScore)/100")
        }
        
        let summary = Summary(
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            fileCount: files.count,
            totalSmells: smellReport.totalSmells,
            smellsByType: smellReport.smellsByType,
            totalFunctions: metricsReport.totalFunctions,
            godFunctions: metricsReport.godFunctions.count,
            averageComplexity: metricsReport.averageComplexity,
            retainCycleRisk: retainReport.riskScore,
            extractionOpportunities: refactorReport.extractionOpportunities.count,
            topGodFunctions: Array(topGodFuncs),
            topIssues: issues
        )
        
        return encodeToJSON(summary)
    }
    
    private func executeAnalyzeFile(path: String) throws -> String {
        let matches = cache.swiftFileURLs.filter {
            $0.lastPathComponent == path || $0.path.hasSuffix(path)
        }
        
        guard !matches.isEmpty else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
        }
        
        if matches.count > 1 {
            let paths = matches.map { $0.path.replacingOccurrences(of: projectRoot.path + "/", with: "") }
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ambiguous path '\(path)' matches \(matches.count) files: \(paths.joined(separator: ", "))"])
        }
        
        let fileURL = matches[0]
        let singleFile = [fileURL]
        
        let smellAnalyzer = CodeSmellAnalyzer()
        let smellReport = smellAnalyzer.analyze(files: singleFile, relativeTo: projectRoot)
        
        let metricsAnalyzer = FunctionMetricsAnalyzer()
        let metricsReport = metricsAnalyzer.analyze(files: singleFile, relativeTo: projectRoot)
        
        let retainAnalyzer = RetainCycleAnalyzer()
        let retainReport = retainAnalyzer.analyze(files: singleFile, relativeTo: projectRoot)
        
        let refactorAnalyzer = RefactoringAnalyzer()
        let refactorReport = refactorAnalyzer.analyze(files: singleFile, relativeTo: projectRoot)
        
        let lineCount = (try? String(contentsOf: fileURL))?.components(separatedBy: "\n").count ?? 0
        
        var score = 100
        score -= min(30, smellReport.totalSmells * 2)
        score -= min(30, metricsReport.godFunctions.count * 10)
        score -= min(20, retainReport.riskScore / 5)
        score -= min(20, max(0, Int(metricsReport.averageComplexity) - 5))
        score = max(0, score)
        
        struct FileAnalysis: Codable {
            let file: String
            let lineCount: Int
            let healthScore: Int
            let smells: Int
            let smellsByType: [String: Int]
            let functions: Int
            let godFunctions: Int
            let averageComplexity: Double
            let retainCycleRisk: Int
            let extractionOpportunities: Int
        }
        
        let analysis = FileAnalysis(
            file: path,
            lineCount: lineCount,
            healthScore: score,
            smells: smellReport.totalSmells,
            smellsByType: smellReport.smellsByType,
            functions: metricsReport.totalFunctions,
            godFunctions: metricsReport.godFunctions.count,
            averageComplexity: metricsReport.averageComplexity,
            retainCycleRisk: retainReport.riskScore,
            extractionOpportunities: refactorReport.extractionOpportunities.count
        )
        
        return encodeToJSON(analysis)
    }
    
    private func executeFindSmells(path: String?) throws -> String {
        let files: [URL]
        if let path = path {
            let matches = cache.swiftFileURLs.filter {
                $0.lastPathComponent == path || $0.path.hasSuffix(path)
            }
            guard !matches.isEmpty else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
            }
            files = matches
        } else {
            files = cache.swiftFileURLs
        }
        
        let analyzer = CodeSmellAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindGodFunctions(minLines: Int, minComplexity: Int) throws -> String {
        let analyzer = FunctionMetricsAnalyzer()
        var report = analyzer.analyze(files: cache.swiftFileURLs, relativeTo: projectRoot)
        
        // Filter by custom thresholds
        report.godFunctions = report.godFunctions.filter {
            $0.lineCount >= minLines || $0.complexity >= minComplexity
        }
        
        return encodeToJSON(report)
    }
    
    private func executeCheckImpact(symbol: String) throws -> String {
        let analyzer = ImpactAnalyzer()
        let report = analyzer.analyze(files: cache.swiftFileURLs, relativeTo: projectRoot, targetSymbol: symbol)
        return encodeToJSON(report)
    }
    
    private func executeSuggestRefactoring(path: String?) throws -> String {
        let files: [URL]
        if let path = path {
            let matches = cache.swiftFileURLs.filter {
                $0.lastPathComponent == path || $0.path.hasSuffix(path)
            }
            guard !matches.isEmpty else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
            }
            files = matches
        } else {
            files = cache.swiftFileURLs
        }
        
        let analyzer = RefactoringAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeTrackProperty(pattern: String) throws -> String {
        let analyzer = PropertyAccessAnalyzer()
        let report = analyzer.analyze(files: cache.swiftFileURLs, relativeTo: projectRoot, targetPattern: pattern)
        return encodeToJSON(report)
    }
    
    private func executeFindCalls(pattern: String) throws -> String {
        let analyzer = MethodCallAnalyzer()
        let report = analyzer.analyze(files: cache.swiftFileURLs, relativeTo: projectRoot, pattern: pattern)
        return encodeToJSON(report)
    }
    
    private func executeListFiles(path: String?) throws -> String {
        var files = cache.swiftFileURLs.map { 
            $0.path.replacingOccurrences(of: projectRoot.path + "/", with: "") 
        }
        
        if let filter = path {
            files = files.filter { $0.contains(filter) }
        }
        
        struct FileList: Codable {
            let count: Int
            let files: [String]
        }
        
        return encodeToJSON(FileList(count: files.count, files: files.sorted()))
    }
    
    private func executeReadSource(path: String, startLine: Int?, endLine: Int?) throws -> String {
        let matches = cache.swiftFileURLs.filter {
            $0.lastPathComponent == path || $0.path.hasSuffix(path)
        }
        
        guard !matches.isEmpty else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
        }
        
        let fileURL = matches[0]
        guard let sourceText = try? String(contentsOf: fileURL) else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read file: \(path)"])
        }
        
        let lines = sourceText.components(separatedBy: "\n")
        let start = max(0, (startLine ?? 1) - 1)
        let end = min(lines.count, endLine ?? lines.count)
        
        let selectedLines = Array(lines[start..<end])
        
        struct SourceResult: Codable {
            let file: String
            let lineRange: String
            let lineCount: Int
            let source: String
        }
        
        return encodeToJSON(SourceResult(
            file: path,
            lineRange: "\(start + 1)-\(end)",
            lineCount: selectedLines.count,
            source: selectedLines.joined(separator: "\n")
        ))
    }
    
    private func executeInvalidateCache(path: String?) -> String {
        if let path = path {
            cache.invalidate(path: path)
            return "{\"status\": \"invalidated\", \"path\": \"\(path)\"}"
        } else {
            cache.invalidateAll()
            return "{\"status\": \"invalidated_all\"}"
        }
    }
    
    private func executeRescanProject() -> String {
        cache.scan(verbose: verbose)
        return "{\"status\": \"rescanned\", \"fileCount\": \(cache.swiftFileURLs.count)}"
    }
    
    // MARK: - Response Helpers
    
    private func sendResult(id: JSONRPCId, result: JSONValue) {
        let response = JSONRPCResponse(id: id, result: result)
        sendResponse(response)
    }
    
    private func sendToolResult(id: JSONRPCId, result: String) {
        let content: JSONValue = .array([
            .object([
                "type": .string("text"),
                "text": .string(result)
            ])
        ])
        let result: JSONValue = .object(["content": content])
        sendResult(id: id, result: result)
    }
    
    private func sendError(id: JSONRPCId, error: JSONRPCError) {
        let response = JSONRPCResponse(id: id, error: error)
        sendResponse(response)
    }
    
    private func sendResponse<T: Encodable>(_ response: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        
        guard let data = try? encoder.encode(response),
              let jsonString = String(data: data, encoding: .utf8) else {
            fputs("[MCP] Error: Failed to encode response\n", stderr)
            return
        }
        
        print(jsonString)
        fflush(stdout)
        
        if verbose {
            fputs("[MCP] -> \(jsonString.prefix(200))\(jsonString.count > 200 ? "..." : "")\n", stderr)
        }
    }
    
    private func encodeToJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"encoding_failed\"}"
        }
        return string
    }
}

// MARK: - Server Entry Point

func runMCPServer(projectPath: String, verbose: Bool) {
    let projectURL = URL(fileURLWithPath: projectPath)
    let server = MCPServer(projectRoot: projectURL, verbose: verbose)
    server.run()
}
