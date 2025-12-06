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

// MARK: - MCP Server

class MCPServer {
    let projectRoot: URL
    let cache: ASTCache
    let verbose: Bool
    
    private var isInitialized = false
    
    init(projectRoot: URL, verbose: Bool = false) {
        self.projectRoot = projectRoot
        self.cache = ASTCache(rootURL: projectRoot)
        self.verbose = verbose
    }
    
    /// Main server loop - reads from stdin, writes to stdout
    func run() {
        if verbose {
            fputs("[MCP] CodeCartographer MCP Server starting...\n", stderr)
            fputs("[MCP] Project root: \(projectRoot.path)\n", stderr)
        }
        
        // Initial scan with AST caching
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
            ),
            // Additional analysis tools
            MCPTool(
                name: "find_singletons",
                description: "Find global state and singleton usage patterns (e.g., .shared, .default)",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_types",
                description: "Analyze type definitions, protocols, and inheritance hierarchy",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_tech_debt",
                description: "Find TODO, FIXME, HACK comment markers in the codebase",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_delegates",
                description: "Analyze delegate wiring patterns and potential issues",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_unused_code",
                description: "Find potentially dead code (unused types and functions)",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_network_calls",
                description: "Find API endpoints and network call patterns",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_reactive",
                description: "Analyze RxSwift/Combine subscriptions and potential memory leaks",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_viewcontrollers",
                description: "Audit ViewController lifecycle patterns and issues",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_localization_issues",
                description: "Find hardcoded strings and measure i18n coverage",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_accessibility_issues",
                description: "Audit accessibility API coverage and find missing accessibility support",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_threading_issues",
                description: "Find thread safety issues and concurrency patterns",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "analyze_swiftui",
                description: "Analyze SwiftUI patterns and state management (@State, @Binding, etc.)",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "analyze_uikit",
                description: "Analyze UIKit patterns and get modernization score",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "analyze_tests",
                description: "Analyze test coverage with target awareness",
                inputSchema: MCPInputSchema()
            ),
            MCPTool(
                name: "analyze_dependencies",
                description: "Analyze CocoaPods, SPM, and Carthage dependencies",
                inputSchema: MCPInputSchema()
            ),
            MCPTool(
                name: "analyze_coredata",
                description: "Analyze Core Data entities, fetch requests, and context usage",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "analyze_docs",
                description: "Audit documentation coverage for public APIs",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "find_retain_cycles",
                description: "Find potential memory leaks and retain cycle risks",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "get_refactor_detail",
                description: "Get detailed extraction info for a specific code block",
                inputSchema: MCPInputSchema(
                    properties: [
                        "file": MCPProperty(type: "string", description: "File name or path"),
                        "startLine": MCPProperty(type: "integer", description: "Start line number"),
                        "endLine": MCPProperty(type: "integer", description: "End line number")
                    ],
                    required: ["file", "startLine", "endLine"]
                )
            ),
            MCPTool(
                name: "analyze_api_surface",
                description: "Get full type signatures, methods, and properties for all public APIs",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
            ),
            MCPTool(
                name: "generate_migration_checklist",
                description: "Generate a phased migration plan from auth analysis",
                inputSchema: MCPInputSchema()
            ),
            MCPTool(
                name: "analyze_auth_migration",
                description: "Track authentication code patterns for migration planning",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to analyze")
                    ]
                )
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
        // Additional analysis tools
        case "find_singletons":
            let path = arguments["path"]?.stringValue
            return try executeFindSingletons(path: path)
        case "find_types":
            let path = arguments["path"]?.stringValue
            return try executeFindTypes(path: path)
        case "find_tech_debt":
            let path = arguments["path"]?.stringValue
            return try executeFindTechDebt(path: path)
        case "find_delegates":
            let path = arguments["path"]?.stringValue
            return try executeFindDelegates(path: path)
        case "find_unused_code":
            let path = arguments["path"]?.stringValue
            return try executeFindUnusedCode(path: path)
        case "find_network_calls":
            let path = arguments["path"]?.stringValue
            return try executeFindNetworkCalls(path: path)
        case "find_reactive":
            let path = arguments["path"]?.stringValue
            return try executeFindReactive(path: path)
        case "find_viewcontrollers":
            let path = arguments["path"]?.stringValue
            return try executeFindViewControllers(path: path)
        case "find_localization_issues":
            let path = arguments["path"]?.stringValue
            return try executeFindLocalizationIssues(path: path)
        case "find_accessibility_issues":
            let path = arguments["path"]?.stringValue
            return try executeFindAccessibilityIssues(path: path)
        case "find_threading_issues":
            let path = arguments["path"]?.stringValue
            return try executeFindThreadingIssues(path: path)
        case "analyze_swiftui":
            let path = arguments["path"]?.stringValue
            return try executeAnalyzeSwiftUI(path: path)
        case "analyze_uikit":
            let path = arguments["path"]?.stringValue
            return try executeAnalyzeUIKit(path: path)
        case "analyze_tests":
            return try executeAnalyzeTests()
        case "analyze_dependencies":
            return try executeAnalyzeDependencies()
        case "analyze_coredata":
            let path = arguments["path"]?.stringValue
            return try executeAnalyzeCoreData(path: path)
        case "analyze_docs":
            let path = arguments["path"]?.stringValue
            return try executeAnalyzeDocs(path: path)
        case "find_retain_cycles":
            let path = arguments["path"]?.stringValue
            return try executeFindRetainCycles(path: path)
        case "get_refactor_detail":
            guard let file = arguments["file"]?.stringValue,
                  let startLine = arguments["startLine"]?.intValue,
                  let endLine = arguments["endLine"]?.intValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameters: file, startLine, endLine"])
            }
            return try executeGetRefactorDetail(file: file, startLine: startLine, endLine: endLine)
        case "analyze_api_surface":
            let path = arguments["path"]?.stringValue
            return try executeAnalyzeAPISurface(path: path)
        case "generate_migration_checklist":
            return try executeGenerateMigrationChecklist()
        case "analyze_auth_migration":
            let path = arguments["path"]?.stringValue
            return try executeAnalyzeAuthMigration(path: path)
        default:
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }
    
    // MARK: - Tool Implementations
    
    private func executeGetSummary() throws -> String {
        let parsedFiles = cache.parsedFiles  // Uses cached ASTs!
        
        let smellAnalyzer = CodeSmellAnalyzer()
        let smellReport = smellAnalyzer.analyze(parsedFiles: parsedFiles)
        
        let metricsAnalyzer = FunctionMetricsAnalyzer()
        let metricsReport = metricsAnalyzer.analyze(parsedFiles: parsedFiles)
        
        let refactorAnalyzer = RefactoringAnalyzer()
        let refactorReport = refactorAnalyzer.analyze(parsedFiles: parsedFiles)
        
        let retainAnalyzer = RetainCycleAnalyzer()
        let retainReport = retainAnalyzer.analyze(parsedFiles: parsedFiles)
        
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
            fileCount: parsedFiles.count,
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
        let matches = cache.fileURLs.filter {
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
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = CodeSmellAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)  // Uses cached ASTs
        return encodeToJSON(report)
    }
    
    private func executeFindGodFunctions(minLines: Int, minComplexity: Int) throws -> String {
        let parsedFiles = cache.parsedFiles
        let analyzer = FunctionMetricsAnalyzer()
        var report = analyzer.analyze(parsedFiles: parsedFiles)  // Uses cached ASTs
        
        // Filter by custom thresholds
        report.godFunctions = report.godFunctions.filter {
            $0.lineCount >= minLines || $0.complexity >= minComplexity
        }
        
        return encodeToJSON(report)
    }
    
    private func executeCheckImpact(symbol: String) throws -> String {
        let parsedFiles = cache.parsedFiles
        let analyzer = ImpactAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles, targetSymbol: symbol)  // Uses cached ASTs
        return encodeToJSON(report)
    }
    
    private func executeSuggestRefactoring(path: String?) throws -> String {
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = RefactoringAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)  // Uses cached ASTs
        return encodeToJSON(report)
    }
    
    private func executeTrackProperty(pattern: String) throws -> String {
        let analyzer = PropertyAccessAnalyzer()
        let report = analyzer.analyze(files: cache.fileURLs, relativeTo: projectRoot, targetPattern: pattern)
        return encodeToJSON(report)
    }
    
    private func executeFindCalls(pattern: String) throws -> String {
        let analyzer = MethodCallAnalyzer()
        let report = analyzer.analyze(files: cache.fileURLs, relativeTo: projectRoot, pattern: pattern)
        return encodeToJSON(report)
    }
    
    private func executeListFiles(path: String?) throws -> String {
        var files = cache.fileURLs.map { 
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
        let matches = cache.fileURLs.filter {
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
            cache.invalidate(path)
            return "{\"status\": \"invalidated\", \"path\": \"\(path)\"}"
        } else {
            cache.invalidateAll()
            return "{\"status\": \"invalidated_all\"}"
        }
    }
    
    private func executeRescanProject() -> String {
        cache.scan(verbose: verbose)
        return "{\"status\": \"rescanned\", \"fileCount\": \(cache.fileCount)}"
    }
    
    // MARK: - Additional Tool Implementations
    
    /// Get ParsedFiles for analyzers that support AST caching
    private func getParsedFiles(for path: String?) throws -> [ParsedFile] {
        return cache.getFiles(matching: path)
    }
    
    /// Get file URLs for analyzers that don't yet support AST caching
    private func getFiles(for path: String?) throws -> [URL] {
        let parsedFiles = cache.getFiles(matching: path)
        guard !parsedFiles.isEmpty || path == nil else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path!)"])
        }
        return parsedFiles.map { $0.url }
    }
    
    private func executeFindSingletons(path: String?) throws -> String {
        let files = try getFiles(for: path)
        
        var nodes: [FileNode] = []
        for fileURL in files {
            if let node = analyzeSingletonFile(at: fileURL, relativeTo: projectRoot) {
                if !node.references.isEmpty || !node.imports.isEmpty {
                    nodes.append(node)
                }
            }
        }
        
        let summary = buildSingletonSummary(from: nodes)
        let result = ExtendedAnalysisResult(
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            rootPath: projectRoot.path,
            fileCount: files.count,
            files: nodes.sorted { $0.references.count > $1.references.count },
            summary: summary,
            targets: nil
        )
        
        return encodeToJSON(result)
    }
    
    private func executeFindTypes(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = DependencyGraphAnalyzer()
        let report = analyzer.analyzeTypes(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindTechDebt(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = TechDebtAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindDelegates(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let depAnalyzer = DependencyGraphAnalyzer()
        let typeMap = depAnalyzer.analyzeTypes(files: files, relativeTo: projectRoot)
        let analyzer = DelegateAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot, typeMap: typeMap)
        return encodeToJSON(report)
    }
    
    private func executeFindUnusedCode(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = UnusedCodeAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot, targetFiles: nil)
        return encodeToJSON(report)
    }
    
    private func executeFindNetworkCalls(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = NetworkAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindReactive(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = ReactiveAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindViewControllers(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = ViewControllerAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindLocalizationIssues(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = LocalizationAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindAccessibilityIssues(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = AccessibilityAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindThreadingIssues(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = ThreadSafetyAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeAnalyzeSwiftUI(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = SwiftUIAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeAnalyzeUIKit(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = UIKitAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeAnalyzeTests() throws -> String {
        // For tests, scan parent directory to find sibling test folders
        let parentURL = projectRoot.deletingLastPathComponent()
        let allFiles = findAllSwiftFiles(in: parentURL)
        let analyzer = TestCoverageAnalyzer()
        let report = analyzer.analyze(files: allFiles, relativeTo: parentURL, targetAnalysis: nil)
        return encodeToJSON(report)
    }
    
    private func executeAnalyzeDependencies() throws -> String {
        let analyzer = DependencyManagerAnalyzer()
        let report = analyzer.analyze(projectRoot: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeAnalyzeCoreData(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = CoreDataAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeAnalyzeDocs(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = DocumentationAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeFindRetainCycles(path: String?) throws -> String {
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = RetainCycleAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)  // Uses cached ASTs
        return encodeToJSON(report)
    }
    
    private func executeGetRefactorDetail(file: String, startLine: Int, endLine: Int) throws -> String {
        let matches = cache.fileURLs.filter {
            $0.lastPathComponent == file || $0.path.hasSuffix(file)
        }
        
        guard !matches.isEmpty else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(file)"])
        }
        
        let fileURL = matches[0]
        guard let sourceText = try? String(contentsOf: fileURL) else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read file: \(file)"])
        }
        
        let lines = sourceText.components(separatedBy: "\n")
        let startIdx = max(0, startLine - 1)
        let endIdx = min(lines.count, endLine)
        let blockLines = Array(lines[startIdx..<endIdx])
        let blockCode = blockLines.joined(separator: "\n")
        
        var externalVars: Set<String> = []
        var functionCalls: Set<String> = []
        var typeRefs: Set<String> = []
        
        let varPattern = #"\b([a-z][a-zA-Z0-9]*)\b"#
        let funcPattern = #"\b([a-zA-Z][a-zA-Z0-9]*)\s*\("#
        let typePattern = #"\b([A-Z][a-zA-Z0-9]*)\b"#
        
        if let varRegex = try? NSRegularExpression(pattern: varPattern) {
            let range = NSRange(blockCode.startIndex..., in: blockCode)
            for match in varRegex.matches(in: blockCode, range: range) {
                if let r = Range(match.range(at: 1), in: blockCode) {
                    externalVars.insert(String(blockCode[r]))
                }
            }
        }
        
        if let funcRegex = try? NSRegularExpression(pattern: funcPattern) {
            let range = NSRange(blockCode.startIndex..., in: blockCode)
            for match in funcRegex.matches(in: blockCode, range: range) {
                if let r = Range(match.range(at: 1), in: blockCode) {
                    functionCalls.insert(String(blockCode[r]))
                }
            }
        }
        
        if let typeRegex = try? NSRegularExpression(pattern: typePattern) {
            let range = NSRange(blockCode.startIndex..., in: blockCode)
            for match in typeRegex.matches(in: blockCode, range: range) {
                if let r = Range(match.range(at: 1), in: blockCode) {
                    typeRefs.insert(String(blockCode[r]))
                }
            }
        }
        
        let keywords: Set<String> = ["if", "else", "let", "var", "for", "in", "return", "guard", "true", "false", "nil", "self"]
        externalVars = externalVars.subtracting(keywords)
        
        let funcName = "extractedFunction"
        let commonParams = ["ctx", "verbose", "rootURL", "rootPath", "swiftFiles", "outputFile", "runAll"]
        let likelyParams = externalVars.filter { commonParams.contains($0) }.sorted()
        
        let paramList = likelyParams.map { param -> String in
            switch param {
            case "ctx": return "ctx: AnalysisContext"
            case "verbose": return "verbose: Bool"
            case "rootURL": return "rootURL: URL"
            case "rootPath": return "rootPath: String"
            case "swiftFiles": return "swiftFiles: [URL]"
            case "outputFile": return "outputFile: String?"
            case "runAll": return "runAll: Bool"
            default: return "\(param): Any"
            }
        }
        
        let hasReturn = blockCode.contains("return")
        let returnType = hasReturn ? " -> Bool" : ""
        let signature = "func \(funcName)(\(paramList.joined(separator: ", ")))\(returnType)"
        let indentedCode = blockLines.map { "    \($0)" }.joined(separator: "\n")
        let generatedFunc = "\(signature) {\n\(indentedCode)\n}"
        
        struct Detail: Codable {
            let file: String
            let lineRange: String
            let lineCount: Int
            let fullCode: String
            let variablesUsed: [String]
            let functionsCalled: [String]
            let typesReferenced: [String]
            let suggestedSignature: String
            let replacementCall: String
            let generatedFunction: String
        }
        
        let detail = Detail(
            file: file,
            lineRange: "\(startLine)-\(endLine)",
            lineCount: blockLines.count,
            fullCode: blockCode,
            variablesUsed: Array(externalVars).sorted(),
            functionsCalled: Array(functionCalls).sorted(),
            typesReferenced: Array(typeRefs).sorted(),
            suggestedSignature: signature,
            replacementCall: hasReturn ? "if \(funcName)(\(likelyParams.joined(separator: ", "))) { return }" : "\(funcName)(\(likelyParams.joined(separator: ", ")))",
            generatedFunction: generatedFunc
        )
        
        return encodeToJSON(detail)
    }
    
    private func executeAnalyzeAPISurface(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = APIAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
    }
    
    private func executeGenerateMigrationChecklist() throws -> String {
        let authAnalyzer = AuthMigrationAnalyzer()
        let authReport = authAnalyzer.analyze(files: cache.fileURLs, relativeTo: projectRoot)
        let generator = MigrationChecklistGenerator()
        let checklist = generator.generateAuthMigrationChecklist(from: authReport)
        return encodeToJSON(checklist)
    }
    
    private func executeAnalyzeAuthMigration(path: String?) throws -> String {
        let files = try getFiles(for: path)
        let analyzer = AuthMigrationAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        return encodeToJSON(report)
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
