import Foundation
import SwiftSyntax
import SwiftParser
import CommonCrypto

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
    private(set) var projectRoot: URL
    private(set) var cache: ASTCache
    let verbose: Bool
    
    private var isInitialized = false
    
    // Semantic search
    private var embeddingIndex: EmbeddingIndex?
    private var embeddingProvider: EmbeddingProvider?
    
    // Background indexing state
    private var isIndexing = false
    private var indexingProgress: (current: Int, total: Int) = (0, 0)
    private var indexingError: String?
    private var indexingStartTime: Date?
    private var indexingEndTime: Date?
    private var indexingBatchSize: Int = 0
    private var indexingProvider: String = ""
    private let indexingLock = NSLock()
    private var dgxBaseURL: URL?  // For job queue API
    private var dgxJobId: String?  // Current job ID for queue manager

    // Default embedding configuration
    private static let defaultDGXEndpoint = "http://192.168.1.159:8080/embed"
    
    // Pending file changes during indexing (processed after indexing completes)
    private var pendingFileChanges: Set<String> = []

    // Cross-instance cache sync
    private var cacheWatcher: DispatchSourceFileSystemObject?
    private var cacheWatcherFD: Int32 = -1
    private var lastKnownCacheModTime: Date?

    /// Get cache file URL for current project
    private func getIndexCacheURL() -> URL {
        // Use ~/.codecartographer/cache/<project-hash>.json
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codecartographer")
            .appendingPathComponent("cache")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Hash project path for filename (SHA256 for uniqueness, no truncation issues)
        guard let pathData = projectRoot.path.data(using: .utf8) else {
            // Fallback to simple hash if UTF-8 encoding fails (shouldn't happen for file paths)
            let fallbackHash = String(projectRoot.path.hashValue, radix: 16)
            return cacheDir.appendingPathComponent("\(fallbackHash).json")
        }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        pathData.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(pathData.count), &hash)
        }
        let projectHash = hash.map { String(format: "%02x", $0) }.joined()
        
        return cacheDir.appendingPathComponent("\(projectHash).json")
    }

    /// Start watching the cache file for changes from other instances
    private func startCacheWatcher() {
        let cacheURL = getIndexCacheURL()

        // Record current modification time
        lastKnownCacheModTime = EmbeddingIndex.getCacheModificationTime(url: cacheURL)

        // Open file descriptor for watching (create file if it doesn't exist)
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            // Touch the file so we can watch it
            FileManager.default.createFile(atPath: cacheURL.path, contents: nil, attributes: nil)
        }

        let fd = open(cacheURL.path, O_EVTONLY)
        guard fd >= 0 else {
            if verbose {
                fputs("[MCP] Failed to open cache file for watching: \(cacheURL.path)\n", stderr)
            }
            return
        }
        cacheWatcherFD = fd

        // Create dispatch source for file changes
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.handleCacheFileChanged()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.cacheWatcherFD, fd >= 0 {
                close(fd)
                self?.cacheWatcherFD = -1
            }
        }

        cacheWatcher = source
        source.resume()

        if verbose {
            fputs("[MCP] Started watching cache file for cross-instance sync: \(cacheURL.lastPathComponent)\n", stderr)
        }
    }

    /// Stop watching the cache file
    private func stopCacheWatcher() {
        cacheWatcher?.cancel()
        cacheWatcher = nil
    }

    /// Handle cache file changes (called when another instance saves)
    private func handleCacheFileChanged() {
        let cacheURL = getIndexCacheURL()

        // Check if modification time actually changed
        guard let newModTime = EmbeddingIndex.getCacheModificationTime(url: cacheURL) else {
            return
        }

        // If this is our own save, lastKnownCacheModTime will be updated in save()
        // This check prevents reloading our own saves
        if let lastKnown = lastKnownCacheModTime, newModTime <= lastKnown {
            return
        }

        // Don't reload while we're actively indexing
        indexingLock.lock()
        let currentlyIndexing = isIndexing
        indexingLock.unlock()

        if currentlyIndexing {
            if verbose {
                fputs("[MCP] Cache file changed but indexing in progress, skipping reload\n", stderr)
            }
            return
        }

        if verbose {
            fputs("[MCP] Cache file changed by another instance, reloading...\n", stderr)
        }

        // Reload the cache
        do {
            try embeddingIndex?.reloadFromCache(url: cacheURL)
            lastKnownCacheModTime = newModTime

            if verbose {
                let count = embeddingIndex?.count ?? 0
                fputs("[MCP] Reloaded \(count) chunks from cache (synced from another instance)\n", stderr)
            }
        } catch {
            if verbose {
                fputs("[MCP] Failed to reload cache: \(error)\n", stderr)
            }
        }
    }

    /// Clean up stale cache files with outdated schema versions
    private func cleanStaleCaches() {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codecartographer")
            .appendingPathComponent("cache")

        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            // Try to read just enough to check schema version
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }

            // Read first 1KB which should contain schemaVersion
            let headerData = handle.readData(ofLength: 1024)
            guard let headerString = String(data: headerData, encoding: .utf8) else { continue }

            // Quick regex check for schema version
            if let range = headerString.range(of: #""schemaVersion"\s*:\s*(\d+)"#, options: .regularExpression) {
                let match = headerString[range]
                if let versionRange = match.range(of: #"\d+"#, options: .regularExpression) {
                    let versionStr = String(match[versionRange])
                    if let version = Int(versionStr), version < EmbeddingIndex.currentSchemaVersion {
                        // Stale cache - delete it
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                        let sizeMB = Double(fileSize) / 1_000_000
                        if verbose {
                            fputs("[MCP] Removing stale cache (schema v\(version) < v\(EmbeddingIndex.currentSchemaVersion)): \(file.lastPathComponent) (\(String(format: "%.1f", sizeMB)) MB)\n", stderr)
                        }
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }
    }

    private var projectExplicitlySet: Bool

    init(projectRoot: URL?, verbose: Bool = false) {
        // Start with provided project or current directory
        self.projectExplicitlySet = projectRoot != nil
        self.projectRoot = projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.cache = ASTCache(rootURL: self.projectRoot)
        self.verbose = verbose
    }
    
    /// Switch to a different project
    /// - Parameters:
    ///   - path: Absolute path to the project root
    ///   - provider: Embedding provider: "dgx" (default, GPU server) or "nlembedding" (local Apple)
    ///   - dgxEndpoint: DGX server endpoint URL (defaults to defaultDGXEndpoint for dgx provider)
    ///   - batchSize: Optional batch size override for embedding indexing
    func setProject(_ path: String, provider: String = "dgx", dgxEndpoint: String? = nil, batchSize: Int? = nil) -> (success: Bool, message: String) {
        let url = URL(fileURLWithPath: path)
        
        // Verify path exists and is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return (false, "Path does not exist or is not a directory: \(path)")
        }
        
        // Use default DGX endpoint if not provided
        let effectiveEndpoint = dgxEndpoint ?? (provider == "dgx" ? MCPServer.defaultDGXEndpoint : nil)

        // Validate DGX endpoint if using DGX provider
        if provider == "dgx" {
            guard let endpoint = effectiveEndpoint, URL(string: endpoint) != nil else {
                return (false, "DGX provider requires a valid dgx_endpoint URL")
            }
        }
        
        // Stop watching old project
        cache.stopWatching()

        // Switch to new project
        projectExplicitlySet = true
        projectRoot = url
        cache = ASTCache(rootURL: url)
        cache.verbose = verbose
        cache.scan(verbose: verbose)
        cache.startWatching()
        
        // Set up incremental re-embedding on file changes
        cache.onFilesChanged = { [weak self] changedFiles in
            self?.handleFilesChanged(changedFiles)
        }
        
        // Background warmup for large projects
        let fileCount = cache.fileCount
        if fileCount >= 50 {
            DispatchQueue.global(qos: .userInitiated).async { [cache, verbose] in
                cache.warmCache(verbose: verbose)
            }
        }
        
        // Clear old index and start background indexing with specified provider
        embeddingIndex = nil
        startBackgroundIndexing(providerName: provider, dgxEndpoint: effectiveEndpoint, batchSize: batchSize)

        let providerDesc = provider == "dgx" ? "DGX (\(effectiveEndpoint ?? ""))" : "NLEmbedding (local)"
        let batchDesc = batchSize.map { ", batch size: \($0)" } ?? ""
        return (true, "Switched to project: \(path) (\(fileCount) Swift files). Background indexing started with \(providerDesc)\(batchDesc).")
    }
    
    /// Main server loop - reads from stdin, writes to stdout
    func run() {
        if verbose {
            fputs("[MCP] CodeCartographer MCP Server starting...\n", stderr)
            fputs("[MCP] Project root: \(projectRoot.path)\n", stderr)
        }

        // Set up incremental re-embedding on file changes (before starting watcher)
        cache.onFilesChanged = { [weak self] changedFiles in
            self?.handleFilesChanged(changedFiles)
        }

        // Do ALL initialization in background so we can respond to MCP immediately
        // This prevents "initialization timed out" errors from Windsurf
        cache.verbose = verbose
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Clean up stale caches from previous schema versions
            self.cleanStaleCaches()

            self.cache.scan(verbose: self.verbose)
            self.cache.startWatching()

            // Smart warmup for larger projects
            let fileCount = self.cache.fileCount
            if fileCount >= 50 {
                self.cache.warmCache(verbose: self.verbose)
            }

            // Only auto-start indexing if project was explicitly provided
            // Otherwise wait for set_project to trigger indexing
            if self.projectExplicitlySet {
                if self.verbose {
                    fputs("[MCP] Auto-starting background indexing with DGX...\n", stderr)
                }
                self.startBackgroundIndexing(providerName: "dgx", dgxEndpoint: MCPServer.defaultDGXEndpoint)
            } else if self.verbose {
                fputs("[MCP] No project specified, waiting for set_project...\n", stderr)
            }

            // Start watching cache file for cross-instance sync
            self.startCacheWatcher()
        }

        if verbose {
            fputs("[MCP] Ready. Listening for JSON-RPC messages on stdin...\n", stderr)
        }

        // Read loop
        while let line = readLine() {
            if line.isEmpty { continue }
            handleMessage(line)
        }

        // Clean up
        cache.stopWatching()
        stopCacheWatcher()

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
                "version": .string("2.1.0")
            ])
        ])
        
        sendResult(id: id, result: result)
    }
    
    private func handleListTools(_ request: JSONRPCRequest) {
        guard let id = request.id else { return }
        
        let tools: [MCPTool] = [
            MCPTool(
                name: "get_version",
                description: "Get CodeCartographer version and server info",
                inputSchema: MCPInputSchema()
            ),
            MCPTool(
                name: "get_summary",
                description: "Get a quick health summary of the Swift project including code smells, god functions, and refactoring opportunities",
                inputSchema: MCPInputSchema()
            ),
            MCPTool(
                name: "get_architecture_diagram",
                description: "Generate a Mermaid.js diagram of the project architecture (inheritance, protocols, dependencies)",
                inputSchema: MCPInputSchema(
                    properties: [
                        "type": MCPProperty(type: "string", description: "Diagram type: 'inheritance', 'protocols', 'dependencies', 'full' (default: full)"),
                        "maxNodes": MCPProperty(type: "integer", description: "Maximum nodes to include (default: 50)")
                    ]
                )
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
                name: "trace_calls",
                description: "Trace call relationships recursively. Use direction='forward' to see what a function calls, 'backward' to see what calls it.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "symbol": MCPProperty(type: "string", description: "The symbol to trace (e.g., 'AuthManager.login', 'fetchUser')"),
                        "direction": MCPProperty(type: "string", description: "Trace direction: 'forward' (what it calls) or 'backward' (what calls it). Default: forward"),
                        "depth": MCPProperty(type: "integer", description: "Maximum recursion depth. Default: 5")
                    ],
                    required: ["symbol"]
                )
            ),
            MCPTool(
                name: "find_call_paths",
                description: "Find execution paths between two symbols. Shows how control flows from source to target.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "from": MCPProperty(type: "string", description: "Source symbol (e.g., 'handleUserInput')"),
                        "to": MCPProperty(type: "string", description: "Target symbol (e.g., 'saveToDatabase')"),
                        "max_paths": MCPProperty(type: "integer", description: "Maximum paths to return. Default: 5"),
                        "max_depth": MCPProperty(type: "integer", description: "Maximum path length. Default: 10")
                    ],
                    required: ["from", "to"]
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
                description: "Find all accesses to a property pattern (e.g., 'Account.*', 'Manager.shared'). Use filterProperty to find specific properties like 'tokens' or 'email'.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "pattern": MCPProperty(type: "string", description: "Property pattern to track (e.g., 'Account.*')"),
                        "filterProperty": MCPProperty(type: "string", description: "Filter to specific property name (e.g., 'tokens', 'email', 'token*' for prefix match, '*Token' for suffix match)")
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
            MCPTool(
                name: "set_project",
                description: "Switch to a different Swift project. Use this to analyze a different codebase without restarting the server.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Absolute path to the Swift project root directory"),
                        "provider": MCPProperty(type: "string", description: "Optional: 'dgx' (default, GPU server) or 'nlembedding' (local Apple)"),
                        "dgx_endpoint": MCPProperty(type: "string", description: "Optional: DGX server endpoint URL (defaults to http://192.168.1.159:8080/embed)"),
                        "batch_size": MCPProperty(type: "integer", description: "Optional: Embedding batch size. Default: 8 for DGX (7B model), 500 for NLEmbedding. Increase for faster indexing if GPU has memory headroom.")
                    ],
                    required: ["path"]
                )
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
                name: "extract_chunks",
                description: "Extract code chunks with rich metadata for semantic search. Returns embeddable text with context, relationships, and domain keywords.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "path": MCPProperty(type: "string", description: "Optional: specific file to extract chunks from"),
                        "kind": MCPProperty(type: "string", description: "Optional: filter by kind (function, method, class, struct, enum, protocol)")
                    ]
                )
            ),
            MCPTool(
                name: "build_search_index",
                description: "Build or rebuild the semantic search index for the project. Uses DGX by default. Call this before using semantic_search.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "provider": MCPProperty(type: "string", description: "Optional: 'dgx' (default) or 'nlembedding'"),
                        "dgx_endpoint": MCPProperty(type: "string", description: "Optional: DGX server endpoint URL (defaults to http://192.168.1.159:8080/embed)")
                    ]
                )
            ),
            MCPTool(
                name: "semantic_search",
                description: "Search the codebase using natural language. Returns the most relevant code chunks. Requires build_search_index to be called first.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "query": MCPProperty(type: "string", description: "Natural language search query (e.g., 'authentication logic', 'network error handling')"),
                        "top_k": MCPProperty(type: "integer", description: "Optional: number of results to return (default: 10)")
                    ],
                    required: ["query"]
                )
            ),
            MCPTool(
                name: "similar_to",
                description: "Find chunks similar to an existing search result. Pass the chunk ID from a previous search result to find related code.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "chunk_id": MCPProperty(type: "string", description: "The chunk ID from a previous search result (e.g., 'summary:Body Scan/Account/Auth/AuthManager.swift')"),
                        "top_k": MCPProperty(type: "integer", description: "Optional: number of results to return (default: 10)")
                    ],
                    required: ["chunk_id"]
                )
            ),
            MCPTool(
                name: "hybrid_search",
                description: "Powerful search combining semantic understanding with code pattern matching. Find code that matches a concept AND contains specific patterns (e.g., 'authentication code with force unwraps'). At least one of query or pattern required.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "query": MCPProperty(type: "string", description: "Optional: semantic search query (e.g., 'authentication logic', 'network handling')"),
                        "pattern": MCPProperty(type: "string", description: "Optional: regex pattern to match in source code (e.g., '!', 'self\\.', '\\.shared')"),
                        "require_pattern": MCPProperty(type: "boolean", description: "If true (default), only return results matching pattern. If false, boost matching results but include non-matches."),
                        "top_k": MCPProperty(type: "integer", description: "Optional: number of results to return (default: 10)")
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
            ),
            MCPTool(
                name: "dgx_health",
                description: "Check DGX embedding server health and configuration",
                inputSchema: MCPInputSchema(
                    properties: [
                        "endpoint": MCPProperty(type: "string", description: "Optional: DGX server base URL (defaults to http://192.168.1.159:8080)")
                    ]
                )
            ),
            MCPTool(
                name: "dgx_stats",
                description: "Get DGX embedding server statistics (requests, throughput, errors)",
                inputSchema: MCPInputSchema(
                    properties: [
                        "endpoint": MCPProperty(type: "string", description: "Optional: DGX server base URL (defaults to http://192.168.1.159:8080)")
                    ]
                )
            ),
            MCPTool(
                name: "indexing_status",
                description: "Check embedding index build progress without interrupting. Returns status (idle/indexing/complete/error), progress percentage, chunks embedded, elapsed time, and ETA.",
                inputSchema: MCPInputSchema(
                    properties: [:]
                )
            ),
            MCPTool(
                name: "build_and_check",
                description: "Build the Swift project and return structured results. Parses compiler errors/warnings with file, line, and suggestions.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "release": MCPProperty(type: "boolean", description: "Build in release mode (default: false, builds debug)"),
                        "clean": MCPProperty(type: "boolean", description: "Clean build folder before building (default: false)")
                    ]
                )
            ),
            MCPTool(
                name: "run_tests",
                description: "Run Swift tests and return structured results. Parses test output for pass/fail status.",
                inputSchema: MCPInputSchema(
                    properties: [
                        "filter": MCPProperty(type: "string", description: "Filter tests by name pattern (e.g., 'CodeSmell' runs only matching tests)"),
                        "verbose": MCPProperty(type: "boolean", description: "Include full test output (default: false)")
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
        case "get_version":
            return executeGetVersion()
        case "get_summary":
            return try executeGetSummary()
        case "get_architecture_diagram":
            let typeStr = arguments["type"]?.stringValue ?? "full"
            let maxNodes = arguments["maxNodes"]?.intValue ?? 50
            return try executeGetArchitectureDiagram(type: typeStr, maxNodes: maxNodes)
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
        case "trace_calls":
            guard let symbol = arguments["symbol"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: symbol"])
            }
            let direction = arguments["direction"]?.stringValue ?? "forward"
            let depth = arguments["depth"]?.intValue ?? 5
            return try executeTraceCalls(symbol: symbol, direction: direction, depth: depth)
        case "find_call_paths":
            guard let from = arguments["from"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: from"])
            }
            guard let to = arguments["to"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: to"])
            }
            let maxPaths = arguments["max_paths"]?.intValue ?? 5
            let maxDepth = arguments["max_depth"]?.intValue ?? 10
            return try executeFindCallPaths(from: from, to: to, maxPaths: maxPaths, maxDepth: maxDepth)
        case "suggest_refactoring":
            let path = arguments["path"]?.stringValue
            return try executeSuggestRefactoring(path: path)
        case "track_property":
            guard let pattern = arguments["pattern"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: pattern"])
            }
            let filterProperty = arguments["filterProperty"]?.stringValue
            return try executeTrackProperty(pattern: pattern, filterProperty: filterProperty)
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
        case "set_project":
            guard let path = arguments["path"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: path"])
            }
            let provider = arguments["provider"]?.stringValue ?? "dgx"
            let dgxEndpoint = arguments["dgx_endpoint"]?.stringValue ?? (provider == "dgx" ? MCPServer.defaultDGXEndpoint : nil)
            let batchSize = arguments["batch_size"]?.intValue
            return executeSetProject(path: path, provider: provider, dgxEndpoint: dgxEndpoint, batchSize: batchSize)
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
        case "extract_chunks":
            let path = arguments["path"]?.stringValue
            let kind = arguments["kind"]?.stringValue
            return try executeExtractChunks(path: path, kind: kind)
        case "build_search_index":
            let provider = arguments["provider"]?.stringValue ?? "dgx"
            let dgxEndpoint = arguments["dgx_endpoint"]?.stringValue ?? (provider == "dgx" ? MCPServer.defaultDGXEndpoint : nil)
            return try executeBuildSearchIndex(provider: provider, dgxEndpoint: dgxEndpoint)
        case "semantic_search":
            guard let query = arguments["query"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: query"])
            }
            let topK = arguments["top_k"]?.intValue ?? 10
            return try executeSemanticSearch(query: query, topK: topK)
        case "similar_to":
            guard let chunkId = arguments["chunk_id"]?.stringValue else {
                throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: chunk_id"])
            }
            let topK = arguments["top_k"]?.intValue ?? 10
            return try executeSimilarTo(chunkId: chunkId, topK: topK)
        case "hybrid_search":
            let query = arguments["query"]?.stringValue
            let pattern = arguments["pattern"]?.stringValue
            let requirePattern = arguments["require_pattern"]?.boolValue ?? true
            let topK = arguments["top_k"]?.intValue ?? 10
            return try executeHybridSearch(query: query, pattern: pattern, requirePattern: requirePattern, topK: topK)
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
        case "dgx_health":
            let endpoint = arguments["endpoint"]?.stringValue ?? "http://192.168.1.159:8080"
            return try executeDGXHealth(endpoint: endpoint)
        case "dgx_stats":
            let endpoint = arguments["endpoint"]?.stringValue ?? "http://192.168.1.159:8080"
            return try executeDGXStats(endpoint: endpoint)
        case "indexing_status":
            return executeIndexingStatus()
        case "build_and_check":
            let release = arguments["release"]?.boolValue ?? false
            let clean = arguments["clean"]?.boolValue ?? false
            return executeBuildAndCheck(release: release, clean: clean)
        case "run_tests":
            let filter = arguments["filter"]?.stringValue
            let verbose = arguments["verbose"]?.boolValue ?? false
            return executeRunTests(filter: filter, verbose: verbose)
        default:
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }
    
    // MARK: - Tool Implementations
    
    private func executeGetVersion() -> String {
        struct VersionInfo: Codable {
            let name: String
            let version: String
            let description: String
            let toolCount: Int
            let currentProject: String?
            let fileCount: Int
        }
        
        let info = VersionInfo(
            name: "CodeCartographer",
            version: "2.1.0",
            description: "Swift Static Analyzer for AI Coding Assistants",
            toolCount: 41,
            currentProject: projectRoot.path,
            fileCount: cache.fileCount
        )
        return encodeToJSON(info)
    }
    
    private func executeGetArchitectureDiagram(type: String, maxNodes: Int) throws -> String {
        let cacheKey = "architecture_diagram:\(type):\(maxNodes)"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = cache.parsedFiles
        
        // Get type map
        let graphAnalyzer = DependencyGraphAnalyzer()
        let typeMap = graphAnalyzer.analyzeTypes(parsedFiles: parsedFiles)
        
        // Determine diagram type
        let diagramType: DiagramType
        switch type.lowercased() {
        case "inheritance": diagramType = .inheritance
        case "protocols": diagramType = .protocols
        case "dependencies": diagramType = .dependencies
        default: diagramType = .full
        }
        
        // Generate diagram
        let diagram = MermaidGenerator.generate(
            typeMap: typeMap,
            singletonTypes: [],  // Could enhance to detect singletons
            diagramType: diagramType,
            maxNodes: maxNodes
        )
        
        let result = encodeToJSON(diagram)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeGetSummary() throws -> String {
        // Check result cache first
        let cacheKey = "get_summary"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = cache.parsedFiles
        
        // Run analyzers in parallel for better performance
        var smellReport: CodeSmellReport!
        var metricsReport: FunctionMetricsReport!
        var refactorReport: RefactoringReport!
        var retainReport: RetainCycleReport!
        
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.codecartographer.analysis", attributes: .concurrent)
        
        group.enter()
        queue.async {
            let analyzer = CodeSmellAnalyzer()
            smellReport = analyzer.analyze(parsedFiles: parsedFiles)
            group.leave()
        }
        
        group.enter()
        queue.async {
            let analyzer = FunctionMetricsAnalyzer()
            metricsReport = analyzer.analyze(parsedFiles: parsedFiles)
            group.leave()
        }
        
        group.enter()
        queue.async {
            let analyzer = RefactoringAnalyzer()
            refactorReport = analyzer.analyze(parsedFiles: parsedFiles)
            group.leave()
        }
        
        group.enter()
        queue.async {
            let analyzer = RetainCycleAnalyzer()
            retainReport = analyzer.analyze(parsedFiles: parsedFiles)
            group.leave()
        }
        
        group.wait()
        
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
        
        let result = encodeToJSON(summary)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeAnalyzeFile(path: String) throws -> String {
        let cacheKey = "analyze_file:\(path)"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = cache.getFiles(matching: path)
        
        guard !parsedFiles.isEmpty else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
        }
        
        if parsedFiles.count > 1 {
            let paths = parsedFiles.map { $0.relativePath }
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ambiguous path '\(path)' matches \(parsedFiles.count) files: \(paths.joined(separator: ", "))"])
        }
        
        let singleFile = parsedFiles
        let lineCount = singleFile[0].sourceText.components(separatedBy: "\n").count
        
        // Run analyzers in parallel
        var smellReport: CodeSmellReport!
        var metricsReport: FunctionMetricsReport!
        var retainReport: RetainCycleReport!
        var refactorReport: RefactoringReport!
        
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.codecartographer.fileanalysis", attributes: .concurrent)
        
        group.enter()
        queue.async {
            smellReport = CodeSmellAnalyzer().analyze(parsedFiles: singleFile)
            group.leave()
        }
        
        group.enter()
        queue.async {
            metricsReport = FunctionMetricsAnalyzer().analyze(parsedFiles: singleFile)
            group.leave()
        }
        
        group.enter()
        queue.async {
            retainReport = RetainCycleAnalyzer().analyze(parsedFiles: singleFile)
            group.leave()
        }
        
        group.enter()
        queue.async {
            refactorReport = RefactoringAnalyzer().analyze(parsedFiles: singleFile)
            group.leave()
        }
        
        group.wait()
        
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
        
        let result = encodeToJSON(analysis)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindSmells(path: String?) throws -> String {
        // Check result cache
        let cacheKey = "find_smells:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = CodeSmellAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindGodFunctions(minLines: Int, minComplexity: Int) throws -> String {
        // Check result cache
        let cacheKey = "find_god_functions:\(minLines):\(minComplexity)"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = cache.parsedFiles
        let analyzer = FunctionMetricsAnalyzer()
        var report = analyzer.analyze(parsedFiles: parsedFiles)
        
        // Filter by custom thresholds
        report.godFunctions = report.godFunctions.filter {
            $0.lineCount >= minLines || $0.complexity >= minComplexity
        }
        
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeCheckImpact(symbol: String) throws -> String {
        let cacheKey = "check_impact:\(symbol)"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }

        let parsedFiles = cache.parsedFiles
        let analyzer = ImpactAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles, targetSymbol: symbol)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }

    private func executeTraceCalls(symbol: String, direction: String, depth: Int) throws -> String {
        let cacheKey = "trace_calls:\(symbol):\(direction):\(depth)"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }

        let parsedFiles = cache.parsedFiles
        let extractor = ChunkExtractor(cache: cache, verbose: verbose)
        let chunks = extractor.extractChunks(from: parsedFiles)
        let tracer = CallGraphTracer(chunks: chunks)

        let trace: CallGraphTracer.CallTrace
        if direction == "backward" {
            trace = tracer.traceBackward(from: symbol, maxDepth: depth)
        } else {
            trace = tracer.traceForward(from: symbol, maxDepth: depth)
        }

        let result = encodeToJSON(trace)
        cache.cacheResult(result, for: cacheKey)
        return result
    }

    private func executeFindCallPaths(from: String, to: String, maxPaths: Int, maxDepth: Int) throws -> String {
        let cacheKey = "find_call_paths:\(from):\(to):\(maxPaths):\(maxDepth)"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }

        let parsedFiles = cache.parsedFiles
        let extractor = ChunkExtractor(cache: cache, verbose: verbose)
        let chunks = extractor.extractChunks(from: parsedFiles)
        let tracer = CallGraphTracer(chunks: chunks)

        let pathResult = tracer.findPaths(from: from, to: to, maxPaths: maxPaths, maxDepth: maxDepth)

        let result = encodeToJSON(pathResult)
        cache.cacheResult(result, for: cacheKey)
        return result
    }

    private func executeSuggestRefactoring(path: String?) throws -> String {
        let cacheKey = "suggest_refactoring:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = RefactoringAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeTrackProperty(pattern: String, filterProperty: String? = nil) throws -> String {
        let cacheKey = "track_property:\(pattern):\(filterProperty ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = cache.parsedFiles
        let analyzer = PropertyAccessAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles, targetPattern: pattern, filterProperty: filterProperty)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindCalls(pattern: String) throws -> String {
        let cacheKey = "find_calls:\(pattern)"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = cache.parsedFiles
        let analyzer = MethodCallAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles, pattern: pattern)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
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
    
    private func executeSetProject(path: String, provider: String = "dgx", dgxEndpoint: String? = nil, batchSize: Int? = nil) -> String {
        let result = setProject(path, provider: provider, dgxEndpoint: dgxEndpoint, batchSize: batchSize)
        if result.success {
            struct SetProjectResult: Codable {
                let status: String
                let project: String
                let fileCount: Int
                let embeddingProvider: String
            }
            return encodeToJSON(SetProjectResult(
                status: "switched",
                project: path,
                fileCount: cache.fileCount,
                embeddingProvider: provider
            ))
        } else {
            struct SetProjectError: Codable {
                let status: String
                let error: String
            }
            return encodeToJSON(SetProjectError(
                status: "error",
                error: result.message
            ))
        }
    }
    
    // MARK: - Additional Tool Implementations
    
    /// Get ParsedFiles for analyzers that support AST caching (auto-scans if needed)
    private func getParsedFiles(for path: String?) throws -> [ParsedFile] {
        return cache.getFiles(matching: path)
    }
    
    /// Get file URLs for analyzers that don't yet support AST caching (auto-scans if needed)
    private func getFiles(for path: String?) throws -> [URL] {
        let parsedFiles = cache.getFiles(matching: path)
        if let path = path, parsedFiles.isEmpty {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
        }
        return parsedFiles.map { $0.url }
    }
    
    private func executeFindSingletons(path: String?) throws -> String {
        let cacheKey = "find_singletons:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
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
        let analysisResult = ExtendedAnalysisResult(
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            rootPath: projectRoot.path,
            fileCount: files.count,
            files: nodes.sorted { $0.references.count > $1.references.count },
            summary: summary,
            targets: nil
        )
        
        let result = encodeToJSON(analysisResult)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindTypes(path: String?) throws -> String {
        let cacheKey = "find_types:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = DependencyGraphAnalyzer()
        let report = analyzer.analyzeTypes(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindTechDebt(path: String?) throws -> String {
        let cacheKey = "find_tech_debt:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = TechDebtAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindDelegates(path: String?) throws -> String {
        let cacheKey = "find_delegates:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let depAnalyzer = DependencyGraphAnalyzer()
        let typeMap = depAnalyzer.analyzeTypes(parsedFiles: parsedFiles)
        let analyzer = DelegateAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles, typeMap: typeMap)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindUnusedCode(path: String?) throws -> String {
        let cacheKey = "find_unused_code:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = UnusedCodeAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles, targetFiles: nil)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindNetworkCalls(path: String?) throws -> String {
        let cacheKey = "find_network_calls:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = NetworkAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindReactive(path: String?) throws -> String {
        let cacheKey = "find_reactive:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = ReactiveAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindViewControllers(path: String?) throws -> String {
        let cacheKey = "find_viewcontrollers:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = ViewControllerAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindLocalizationIssues(path: String?) throws -> String {
        let cacheKey = "find_localization_issues:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = LocalizationAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindAccessibilityIssues(path: String?) throws -> String {
        let cacheKey = "find_accessibility_issues:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = AccessibilityAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindThreadingIssues(path: String?) throws -> String {
        let cacheKey = "find_threading_issues:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = ThreadSafetyAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeExtractChunks(path: String?, kind: String?) throws -> String {
        let cacheKey = "extract_chunks:\(path ?? "all"):\(kind ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let extractor = ChunkExtractor(cache: cache, verbose: verbose)
        var chunks = extractor.extractChunks(from: parsedFiles)
        
        // Filter by kind if specified
        if let kindFilter = kind {
            chunks = chunks.filter { $0.kind.rawValue == kindFilter }
        }
        
        // Build response with both chunks and sample embedding texts
        struct ChunkReport: Codable {
            let totalChunks: Int
            let byKind: [String: Int]
            let chunks: [CodeChunk]
            let sampleEmbeddingTexts: [String]
        }
        
        // Count by kind
        var byKind: [String: Int] = [:]
        for chunk in chunks {
            byKind[chunk.kind.rawValue, default: 0] += 1
        }
        
        // Get sample embedding texts (first 5)
        let samples = chunks.prefix(5).map { $0.embeddingText }
        
        let report = ChunkReport(
            totalChunks: chunks.count,
            byKind: byKind,
            chunks: chunks,
            sampleEmbeddingTexts: samples
        )
        
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    // MARK: - Semantic Search (Background Indexing)
    
    /// Start background indexing (called automatically on project switch)
    /// - Parameters:
    ///   - providerName: "dgx" or "nlembedding"
    ///   - dgxEndpoint: URL for DGX server (defaults to defaultDGXEndpoint for dgx provider)
    ///   - batchSize: Optional batch size override. Default: 8 for DGX, 500 for NLEmbedding
    private func startBackgroundIndexing(providerName: String = "dgx", dgxEndpoint: String? = nil, batchSize: Int? = nil) {
        indexingLock.lock()
        // Don't start if already indexing
        if isIndexing {
            indexingLock.unlock()
            return
        }
        isIndexing = true
        indexingProgress = (0, 0)
        indexingError = nil
        indexingStartTime = Date()
        indexingEndTime = nil
        indexingProvider = providerName
        indexingBatchSize = batchSize ?? (providerName.lowercased() == "dgx" ? 32 : 500)
        pendingFileChanges.removeAll()  // Clear any stale file changes from before indexing
        indexingLock.unlock()
        
        if verbose { fputs("[MCP] Starting background indexing...\n", stderr) }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Create embedding provider
                let provider: EmbeddingProvider
                switch providerName.lowercased() {
                case "nlembedding":
                    provider = try NLEmbeddingProvider()
                case "dgx":
                    let endpoint = dgxEndpoint ?? MCPServer.defaultDGXEndpoint
                    guard let url = URL(string: endpoint) else {
                        throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "DGX provider requires valid dgx_endpoint URL"])
                    }
                    provider = DGXEmbeddingProvider(endpoint: url)
                    // Store base URL for progress reporting (strip /embed)
                    self.dgxBaseURL = url.deletingLastPathComponent()
                default:
                    // Default to DGX
                    guard let url = URL(string: MCPServer.defaultDGXEndpoint) else {
                        throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid default DGX endpoint"])
                    }
                    provider = DGXEmbeddingProvider(endpoint: url)
                    self.dgxBaseURL = url.deletingLastPathComponent()
                }
                
                self.embeddingProvider = provider
                let newIndex = EmbeddingIndex(provider: provider, verbose: self.verbose)
                
                // Extract chunks
                let parsedFiles = self.cache.parsedFiles
                let extractor = ChunkExtractor(cache: self.cache, verbose: self.verbose)
                let allChunks = extractor.extractChunks(from: parsedFiles)
                
                // Build file hash map
                var fileHashes: [String: String] = [:]
                for file in parsedFiles {
                    fileHashes[file.relativePath] = file.contentHash
                }
                newIndex.setFileHashes(fileHashes)
                
                // Try to load from cache
                let cacheURL = self.getIndexCacheURL()
                var changedFiles: Set<String> = []
                var loadedFromCache = false
                var cacheWasComplete = false
                var cachedJobId: String? = nil

                if FileManager.default.fileExists(atPath: cacheURL.path) {
                    do {
                        let loadResult = try newIndex.load(from: cacheURL, currentHashes: fileHashes)
                        changedFiles = loadResult.changedFiles
                        cacheWasComplete = loadResult.wasComplete
                        cachedJobId = loadResult.dgxJobId
                        loadedFromCache = true
                        if self.verbose {
                            let statusStr = cacheWasComplete ? "complete" : "checkpoint"
                            let jobStr = cachedJobId.map { " job=\($0)" } ?? ""
                            fputs("[MCP] Loaded \(newIndex.count) embeddings from cache (\(statusStr)\(jobStr)), \(changedFiles.count) files need re-embedding\n", stderr)
                        }
                    } catch {
                        if self.verbose { fputs("[MCP] Cache load failed: \(error.localizedDescription), rebuilding...\n", stderr) }
                        // Delete invalid cache to free disk space
                        try? FileManager.default.removeItem(at: cacheURL)
                        changedFiles = Set(fileHashes.keys)  // Re-embed all
                    }
                } else {
                    changedFiles = Set(fileHashes.keys)  // No cache, embed all
                }

                // Determine which chunks need embedding:
                // - If cache was complete: only embed chunks from changed files
                // - If cache was checkpoint (incomplete): embed ALL chunks not already in cache
                let chunksToEmbed: [CodeChunk]
                if loadedFromCache && cacheWasComplete {
                    // Complete cache - only embed changed files
                    chunksToEmbed = allChunks.filter { changedFiles.contains($0.file) }
                } else if loadedFromCache {
                    // Checkpoint cache - embed chunks not already cached
                    let cachedChunkIds = Set(newIndex.getAllChunkIds())
                    chunksToEmbed = allChunks.filter { !cachedChunkIds.contains($0.id) }
                    if self.verbose && !chunksToEmbed.isEmpty {
                        fputs("[MCP] Resuming from checkpoint: \(cachedChunkIds.count) cached, \(chunksToEmbed.count) remaining\n", stderr)
                    }
                } else {
                    // No cache - embed all
                    chunksToEmbed = allChunks
                }

                let totalChunks = allChunks.count

                // Update total
                self.indexingLock.lock()
                self.indexingProgress = (0, chunksToEmbed.count)
                self.indexingLock.unlock()

                if chunksToEmbed.isEmpty {
                    if self.verbose { fputs("[MCP] All \(allChunks.count) chunks loaded from cache, no embedding needed!\n", stderr) }
                } else {
                    if self.verbose {
                        fputs("[MCP] Embedding \(chunksToEmbed.count) chunks (\(allChunks.count - chunksToEmbed.count) cached)...\n", stderr)
                    }

                    // Check if we have a cached job ID from a previous checkpoint
                    var serverRecommendedBatchSize: Int? = nil
                    if let existingJobId = cachedJobId {
                        let jobStatus = self.checkJobStatus(jobId: existingJobId)
                        if let status = jobStatus, status == "active" || status == "queued" {
                            // Resume existing job
                            self.dgxJobId = existingJobId
                            if self.verbose {
                                fputs("[MCP] Resuming existing job \(existingJobId) (status: \(status))\n", stderr)
                            }
                        } else {
                            // Job expired/completed/failed, register new one
                            if self.verbose, let status = jobStatus {
                                fputs("[MCP] Cached job \(existingJobId) is \(status), registering new job\n", stderr)
                            }
                            if let result = self.registerJobWithDGX(totalChunks: chunksToEmbed.count) {
                                self.dgxJobId = result.jobId
                                serverRecommendedBatchSize = result.recommendedBatchSize
                            }
                        }
                    } else {
                        // No cached job, register new one
                        if let result = self.registerJobWithDGX(totalChunks: chunksToEmbed.count) {
                            self.dgxJobId = result.jobId
                            serverRecommendedBatchSize = result.recommendedBatchSize
                        }
                    }

                    // Wait for our turn in the queue (other instances may be using GPU)
                    if self.dgxJobId != nil && !self.waitForJobActive() {
                        throw NSError(domain: "MCP", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "Job queue timeout - GPU busy for too long"
                        ])
                    }

                    // Index in batches with progress updates
                    // Use server-recommended batch size if available, otherwise use defaults
                    let defaultBatchSize: Int
                    if let serverBatch = serverRecommendedBatchSize {
                        defaultBatchSize = serverBatch
                    } else {
                        defaultBatchSize = providerName.lowercased() == "dgx" ? 32 : 500
                    }
                    let actualBatchSize = batchSize ?? defaultBatchSize
                    self.indexingBatchSize = actualBatchSize
                    if self.verbose { fputs("[MCP] Using batch size: \(actualBatchSize)\n", stderr) }

                    // Checkpoint every 500 chunks for resumability
                    let checkpointInterval = 500
                    var chunksSinceCheckpoint = 0

                    for batchStart in stride(from: 0, to: chunksToEmbed.count, by: actualBatchSize) {
                        let batchEnd = min(batchStart + actualBatchSize, chunksToEmbed.count)
                        let batch = Array(chunksToEmbed[batchStart..<batchEnd])
                        try newIndex.index(batch)

                        self.indexingLock.lock()
                        self.indexingProgress = (batchEnd, chunksToEmbed.count)
                        self.indexingLock.unlock()

                        // Report progress to DGX dashboard
                        self.reportProgressToDGX(current: batchEnd, total: chunksToEmbed.count)

                        // Checkpoint save for resumability (marked incomplete so we resume on restart)
                        chunksSinceCheckpoint += batch.count
                        if chunksSinceCheckpoint >= checkpointInterval {
                            do {
                                try newIndex.save(to: cacheURL, isComplete: false, totalExpectedChunks: totalChunks, dgxJobId: self.dgxJobId)
                                self.lastKnownCacheModTime = EmbeddingIndex.getCacheModificationTime(url: cacheURL)
                                if self.verbose { fputs("[MCP] Checkpoint saved at \(batchEnd)/\(chunksToEmbed.count) (incomplete, job=\(self.dgxJobId ?? "none"))\n", stderr) }
                            } catch {
                                fputs("[MCP] Warning: Checkpoint save failed: \(error.localizedDescription)\n", stderr)
                            }
                            chunksSinceCheckpoint = 0
                        }

                        if self.verbose { fputs("[MCP] Embedded \(batchEnd)/\(chunksToEmbed.count)\n", stderr) }
                    }
                }

                // Final save (marked complete, no job ID since indexing is done)
                do {
                    try newIndex.save(to: cacheURL, isComplete: true, totalExpectedChunks: totalChunks, dgxJobId: nil)
                    // Update our known mod time to prevent reloading our own save
                    self.lastKnownCacheModTime = EmbeddingIndex.getCacheModificationTime(url: cacheURL)
                } catch {
                    fputs("[MCP] Warning: Failed to save index cache: \(error.localizedDescription)\n", stderr)
                }
                
                // Done - set the index
                self.embeddingIndex = newIndex
                
                self.indexingLock.lock()
                self.isIndexing = false
                self.indexingEndTime = Date()
                self.indexingLock.unlock()
                
                // Mark job complete on DGX queue
                self.completeJobOnDGX()

                // Log completion with timing
                if let startTime = self.indexingStartTime, let endTime = self.indexingEndTime {
                    let duration = endTime.timeIntervalSince(startTime)
                    let minutes = Int(duration) / 60
                    let seconds = Int(duration) % 60
                    let cachedCount = allChunks.count - chunksToEmbed.count
                    fputs("[MCP] Indexing complete! \(allChunks.count) chunks (\(cachedCount) cached, \(chunksToEmbed.count) embedded) in \(minutes)m \(seconds)s (batch=\(self.indexingBatchSize), provider=\(providerName))\n", stderr)
                } else if self.verbose {
                    fputs("[MCP] Background indexing complete!\n", stderr)
                }
                
                // Process any file changes that occurred during indexing
                self.indexingLock.lock()
                let pending = self.pendingFileChanges
                self.pendingFileChanges.removeAll()
                self.indexingLock.unlock()
                
                if !pending.isEmpty {
                    if self.verbose {
                        fputs("[MCP] Processing \(pending.count) queued file changes...\n", stderr)
                    }
                    self.handleFilesChanged(pending)
                }
                
            } catch {
                self.indexingLock.lock()
                self.isIndexing = false
                self.indexingError = error.localizedDescription
                self.indexingLock.unlock()

                // Mark job failed on DGX queue
                self.failJobOnDGX(error: error.localizedDescription)

                fputs("[MCP] Background indexing failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
    
    /// Get current indexing status
    private func getIndexingStatus() -> (isIndexing: Bool, progress: (Int, Int), error: String?) {
        indexingLock.lock()
        defer { indexingLock.unlock() }
        return (isIndexing, indexingProgress, indexingError)
    }

    // MARK: - DGX Job Queue API

    /// Result of job registration
    struct JobRegistrationResult {
        let jobId: String
        let recommendedBatchSize: Int?
    }

    /// Register a new indexing job with the DGX job queue
    /// Returns job ID and recommended batch size if successful, nil if registration failed
    private func registerJobWithDGX(totalChunks: Int) -> JobRegistrationResult? {
        guard let baseURL = dgxBaseURL else { return nil }
        let jobsURL = baseURL.appendingPathComponent("jobs")

        var request = URLRequest(url: jobsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let projectName = projectRoot.lastPathComponent
        let instanceId = ProcessInfo.processInfo.processIdentifier
        let payload: [String: Any] = [
            "project": projectName,
            "total_chunks": totalChunks,
            "instance_id": "codecart-\(instanceId)"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        var result: JobRegistrationResult?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["job_id"] as? String else { return }
            let batchSize = json["recommended_batch_size"] as? Int
            result = JobRegistrationResult(jobId: id, recommendedBatchSize: batchSize)
        }
        task.resume()
        semaphore.wait()

        if let r = result, verbose {
            let batchStr = r.recommendedBatchSize.map { ", batch=\($0)" } ?? ""
            fputs("[MCP] Registered job \(r.jobId) with DGX queue\(batchStr)\n", stderr)
        }
        return result
    }

    /// Check status of an existing job on the DGX server
    /// Returns status string ("active", "queued", "completed", "failed") or nil if not found
    private func checkJobStatus(jobId: String) -> String? {
        guard let baseURL = dgxBaseURL else { return nil }
        let jobURL = baseURL.appendingPathComponent("jobs").appendingPathComponent(jobId)

        var request = URLRequest(url: jobURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        var status: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = json["status"] as? String else { return }
            status = s
        }
        task.resume()
        semaphore.wait()

        return status
    }

    /// Wait for job to become active (poll until status is "active")
    /// Returns true if job is active, false if timeout or error
    private func waitForJobActive(timeout: TimeInterval = 300) -> Bool {
        guard let baseURL = dgxBaseURL, let jobId = dgxJobId else { return true }
        let jobURL = baseURL.appendingPathComponent("jobs").appendingPathComponent(jobId)

        let startTime = Date()
        var isActive = false
        var lastStatus = ""

        while Date().timeIntervalSince(startTime) < timeout {
            var request = URLRequest(url: jobURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10

            var currentStatus: String?
            var queuePosition: Int?
            let semaphore = DispatchSemaphore(value: 0)

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }
                guard error == nil,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? String else { return }
                currentStatus = status
                queuePosition = json["queue_position"] as? Int
            }
            task.resume()
            semaphore.wait()

            if let status = currentStatus {
                if status == "active" {
                    isActive = true
                    if verbose { fputs("[MCP] Job \(jobId) is now active\n", stderr) }
                    break
                } else if status == "queued" {
                    if status != lastStatus {
                        let pos = queuePosition.map { " (position \($0))" } ?? ""
                        fputs("[MCP] Job \(jobId) queued\(pos), waiting for GPU...\n", stderr)
                        lastStatus = status
                    }
                } else if status == "failed" || status == "completed" {
                    fputs("[MCP] Job \(jobId) has status '\(status)', cannot proceed\n", stderr)
                    break
                }
            }

            // Poll every 2 seconds
            Thread.sleep(forTimeInterval: 2)
        }

        return isActive
    }

    /// Report indexing progress to DGX job queue
    private func reportProgressToDGX(current: Int, total: Int) {
        guard let baseURL = dgxBaseURL, let jobId = dgxJobId else { return }
        let progressURL = baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(jobId)
            .appendingPathComponent("progress")

        var request = URLRequest(url: progressURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let payload: [String: Any] = ["current": current]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        // Fire and forget
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Mark job as completed on DGX
    private func completeJobOnDGX() {
        guard let baseURL = dgxBaseURL, let jobId = dgxJobId else { return }
        let completeURL = baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(jobId)
            .appendingPathComponent("complete")

        var request = URLRequest(url: completeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        // Fire and forget
        URLSession.shared.dataTask(with: request).resume()
        if verbose { fputs("[MCP] Job \(jobId) marked complete\n", stderr) }
        dgxJobId = nil
    }

    /// Mark job as failed on DGX
    private func failJobOnDGX(error: String) {
        guard let baseURL = dgxBaseURL, let jobId = dgxJobId else { return }
        let failURL = baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(jobId)
            .appendingPathComponent("fail")

        var request = URLRequest(url: failURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let payload: [String: Any] = ["error": error]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        // Fire and forget
        URLSession.shared.dataTask(with: request).resume()
        if verbose { fputs("[MCP] Job \(jobId) marked failed: \(error)\n", stderr) }
        dgxJobId = nil
    }

    /// Handle file changes for incremental re-embedding
    private func handleFilesChanged(_ changedFiles: Set<String>) {
        guard !changedFiles.isEmpty else { return }
        guard let index = embeddingIndex, !index.isEmpty else { return }
        
        // Queue changes if full indexing is in progress (will process after)
        let status = getIndexingStatus()
        if status.isIndexing {
            indexingLock.lock()
            pendingFileChanges.formUnion(changedFiles)
            indexingLock.unlock()
            if verbose {
                fputs("[MCP] Queued \(changedFiles.count) file changes (indexing in progress)\n", stderr)
            }
            return
        }
        
        if verbose {
            fputs("[MCP] Files changed: \(changedFiles.joined(separator: ", "))\n", stderr)
        }
        
        // Perform incremental re-embedding in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let extractor = ChunkExtractor(cache: self.cache, verbose: self.verbose)

                // 1. Remove old chunks for changed files AND all virtual chunks
                //    (virtual chunks depend on entire codebase and need regeneration)
                index.removeChunksForFiles(changedFiles)
                index.removeVirtualChunks()

                // 2. Get ALL parsed files (needed for virtual chunk generation)
                let allParsedFiles = self.cache.parsedFiles
                let changedParsedFiles = allParsedFiles.filter { changedFiles.contains($0.relativePath) }

                // 3. Extract file-level chunks for changed files only
                let newFileChunks = extractor.extractFileChunks(from: changedParsedFiles)

                // 4. Update file hashes for changed files
                var newFileHashes: [String: String] = [:]
                for file in changedParsedFiles {
                    newFileHashes[file.relativePath] = file.contentHash
                }
                index.updateFileHashes(newFileHashes)

                // 5. Get all file chunks (existing + new) for virtual chunk generation
                var allFileChunks = index.getFileChunks()
                allFileChunks.append(contentsOf: newFileChunks)

                // 6. Generate virtual chunks based on complete codebase state
                let virtualChunks = extractor.generateVirtualChunks(from: allFileChunks, parsedFiles: allParsedFiles)

                // 7. Embed new file chunks and virtual chunks
                var chunksToEmbed: [CodeChunk] = []
                chunksToEmbed.append(contentsOf: newFileChunks)
                chunksToEmbed.append(contentsOf: virtualChunks)

                if !chunksToEmbed.isEmpty {
                    try index.index(chunksToEmbed)

                    if self.verbose {
                        fputs("[MCP] Incremental re-embed: \(newFileChunks.count) file chunks + \(virtualChunks.count) virtual chunks for \(changedFiles.count) changed files\n", stderr)
                    }
                }

                // 8. Save updated index to cache (incremental update to complete index)
                let cacheURL = self.getIndexCacheURL()
                try index.save(to: cacheURL, isComplete: true, totalExpectedChunks: index.count)
                // Update our known mod time to prevent reloading our own save
                self.lastKnownCacheModTime = EmbeddingIndex.getCacheModificationTime(url: cacheURL)

            } catch {
                fputs("[MCP] Incremental re-embedding failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
    
    private func executeBuildSearchIndex(provider: String, dgxEndpoint: String?) throws -> String {
        // Check if already indexing
        let status = getIndexingStatus()
        if status.isIndexing {
            let percent = status.progress.1 > 0 ? Int(Double(status.progress.0) / Double(status.progress.1) * 100) : 0
            struct IndexingReport: Codable {
                let status: String
                let progress: Int
                let current: Int
                let total: Int
                let message: String
            }
            let report = IndexingReport(
                status: "indexing",
                progress: percent,
                current: status.progress.0,
                total: status.progress.1,
                message: "Indexing in progress (\(percent)%). Use semantic_search to check status."
            )
            return encodeToJSON(report)
        }
        
        // Check if already indexed
        if let index = embeddingIndex, !index.isEmpty {
            struct IndexReport: Codable {
                let status: String
                let chunksIndexed: Int
                let durationSeconds: Double?
                let batchSize: Int?
                let provider: String?
                let message: String
            }
            
            // Calculate duration if we have timing data
            var duration: Double? = nil
            if let start = indexingStartTime, let end = indexingEndTime {
                duration = end.timeIntervalSince(start)
            }
            
            let durationStr = duration.map { d in
                let mins = Int(d) / 60
                let secs = Int(d) % 60
                return " Indexed in \(mins)m \(secs)s."
            } ?? ""
            
            let report = IndexReport(
                status: "ready",
                chunksIndexed: index.count,
                durationSeconds: duration,
                batchSize: indexingBatchSize > 0 ? indexingBatchSize : nil,
                provider: indexingProvider.isEmpty ? nil : indexingProvider,
                message: "Index ready with \(index.count) chunks.\(durationStr) Use semantic_search to query."
            )
            return encodeToJSON(report)
        }
        
        // Start background indexing
        startBackgroundIndexing(providerName: provider, dgxEndpoint: dgxEndpoint)
        
        struct IndexReport: Codable {
            let status: String
            let message: String
        }
        let report = IndexReport(
            status: "started",
            message: "Background indexing started. Use semantic_search to check status or query when ready."
        )
        return encodeToJSON(report)
    }
    
    private func executeSemanticSearch(query: String, topK: Int) throws -> String {
        // Check if indexing in progress
        let status = getIndexingStatus()
        if status.isIndexing {
            let percent = status.progress.1 > 0 ? Int(Double(status.progress.0) / Double(status.progress.1) * 100) : 0
            struct IndexingReport: Codable {
                let status: String
                let progress: Int
                let message: String
            }
            let report = IndexingReport(
                status: "indexing",
                progress: percent,
                message: "Index is being built (\(percent)% complete). Please wait and try again."
            )
            return encodeToJSON(report)
        }
        
        // Check for indexing error
        if let error = status.error {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Indexing failed: \(error). Call build_search_index to retry."])
        }
        
        guard let index = embeddingIndex, !index.isEmpty else {
            // Start indexing if not started
            startBackgroundIndexing()
            struct IndexingReport: Codable {
                let status: String
                let message: String
            }
            let report = IndexingReport(
                status: "indexing",
                message: "Index not built. Background indexing started. Please wait and try again."
            )
            return encodeToJSON(report)
        }
        
        if verbose { fputs("[MCP] Searching for: \(query)\n", stderr) }
        
        let results = try index.search(query: query, topK: topK)
        
        struct SearchReport: Codable {
            let query: String
            let resultsCount: Int
            let results: [SearchResultItem]
        }
        
        struct SearchResultItem: Codable {
            let score: Float
            let file: String
            let line: Int
            let name: String
            let kind: String
            let signature: String
            let layer: String
            let embeddingText: String
        }
        
        let items = results.map { result in
            SearchResultItem(
                score: result.score,
                file: result.chunk.file,
                line: result.chunk.line,
                name: result.chunk.name,
                kind: result.chunk.kind.rawValue,
                signature: result.chunk.signature,
                layer: result.chunk.layer,
                embeddingText: result.chunk.embeddingText
            )
        }
        
        let report = SearchReport(
            query: query,
            resultsCount: results.count,
            results: items
        )
        
        return encodeToJSON(report)
    }
    
    private func executeSimilarTo(chunkId: String, topK: Int) throws -> String {
        guard let index = embeddingIndex, !index.isEmpty else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Index not built. Call build_search_index first."])
        }
        
        // Check if chunk exists
        guard index.getChunk(chunkId) != nil else {
            throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chunk not found: \(chunkId)"])
        }
        
        if verbose { fputs("[MCP] Finding similar to: \(chunkId)\n", stderr) }
        
        let results = index.similarTo(chunkId: chunkId, topK: topK)
        
        struct SimilarReport: Codable {
            let sourceChunkId: String
            let resultsCount: Int
            let results: [SearchResultItem]
        }
        
        struct SearchResultItem: Codable {
            let score: Float
            let chunkId: String
            let file: String
            let line: Int
            let name: String
            let kind: String
            let signature: String
            let layer: String
            let purpose: String?
        }
        
        let items = results.map { result in
            SearchResultItem(
                score: result.score,
                chunkId: result.chunk.id,
                file: result.chunk.file,
                line: result.chunk.line,
                name: result.chunk.name,
                kind: result.chunk.kind.rawValue,
                signature: result.chunk.signature,
                layer: result.chunk.layer,
                purpose: result.chunk.purpose
            )
        }
        
        let report = SimilarReport(
            sourceChunkId: chunkId,
            resultsCount: results.count,
            results: items
        )
        
        return encodeToJSON(report)
    }

    private func executeHybridSearch(query: String?, pattern: String?, requirePattern: Bool, topK: Int) throws -> String {
        // Validate at least one of query or pattern
        guard query != nil || pattern != nil else {
            throw NSError(domain: "MCP", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "At least one of 'query' or 'pattern' must be provided"
            ])
        }

        // Check indexing status
        let status = getIndexingStatus()
        if status.isIndexing {
            let percent = status.progress.1 > 0 ? Int(Double(status.progress.0) / Double(status.progress.1) * 100) : 0
            struct IndexingReport: Codable {
                let status: String
                let progress: Int
                let message: String
            }
            let report = IndexingReport(
                status: "indexing",
                progress: percent,
                message: "Index is being built (\(percent)% complete). Please wait and try again."
            )
            return encodeToJSON(report)
        }

        guard let index = embeddingIndex, !index.isEmpty else {
            startBackgroundIndexing()
            struct IndexingReport: Codable {
                let status: String
                let message: String
            }
            let report = IndexingReport(
                status: "indexing",
                message: "Index not built. Background indexing started. Please wait and try again."
            )
            return encodeToJSON(report)
        }

        // Compile regex if pattern provided
        var regex: NSRegularExpression? = nil
        if let pattern = pattern {
            do {
                regex = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw NSError(domain: "MCP", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid regex pattern: \(error.localizedDescription)"
                ])
            }
        }

        if verbose {
            fputs("[MCP] Hybrid search - query: \(query ?? "none"), pattern: \(pattern ?? "none"), require: \(requirePattern)\n", stderr)
        }

        // Get candidates
        var candidates: [(chunk: CodeChunk, score: Float)] = []

        if let query = query {
            // Semantic search with higher limit to allow filtering
            let searchLimit = pattern != nil ? max(100, topK * 10) : topK
            let results = try index.search(query: query, topK: searchLimit)
            candidates = results.map { ($0.chunk, $0.score) }
        } else {
            // Pattern-only: get all chunks with neutral score
            let allIds = index.getAllChunkIds()
            candidates = allIds.compactMap { id -> (CodeChunk, Float)? in
                guard let chunk = index.getChunk(id) else { return nil }
                return (chunk, 0.5) // Neutral score for pattern-only search
            }
        }

        // Filter/boost by pattern
        struct ScoredResult {
            let chunk: CodeChunk
            var score: Float
            var matchContext: String?
            var matchCount: Int
            var sourceLines: [String]
        }

        var results: [ScoredResult] = []
        let boostAmount: Float = 0.2

        for (chunk, score) in candidates {
            // Read source to check pattern
            var matchContext: String? = nil
            var matchCount = 0

            // Always get source code for inline display
            let sourceLines = getSourceForChunk(chunk)

            if let regex = regex {
                // Check pattern against source
                let sourceText = sourceLines.joined(separator: "\n")

                let range = NSRange(sourceText.startIndex..., in: sourceText)
                let matches = regex.matches(in: sourceText, options: [], range: range)
                matchCount = matches.count

                if matchCount > 0 {
                    // Extract first few match contexts
                    var contexts: [String] = []
                    for match in matches.prefix(3) {
                        if let matchRange = Range(match.range, in: sourceText) {
                            // Get surrounding context (the line containing the match)
                            let matchStr = String(sourceText[matchRange])
                            let lineStart = sourceText[..<matchRange.lowerBound].lastIndex(of: "\n").map { sourceText.index(after: $0) } ?? sourceText.startIndex
                            let lineEnd = sourceText[matchRange.upperBound...].firstIndex(of: "\n") ?? sourceText.endIndex
                            let line = String(sourceText[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
                            if line.count <= 120 {
                                contexts.append(line)
                            } else {
                                contexts.append(matchStr)
                            }
                        }
                    }
                    var contextStr = contexts.joined(separator: " | ")
                    if matches.count > 3 {
                        contextStr += " (+\(matches.count - 3) more)"
                    }
                    matchContext = contextStr
                }

                if requirePattern && matchCount == 0 {
                    continue // Skip non-matches when pattern is required
                }
            }

            // Calculate final score
            var finalScore = score
            if matchCount > 0 && !requirePattern {
                // Boost score for matches when not required
                finalScore = min(1.0, score + boostAmount)
            }

            results.append(ScoredResult(
                chunk: chunk,
                score: finalScore,
                matchContext: matchContext,
                matchCount: matchCount,
                sourceLines: sourceLines
            ))
        }

        // Sort by score descending and take topK
        results.sort { $0.score > $1.score }
        results = Array(results.prefix(topK))

        // Build response
        struct HybridSearchReport: Codable {
            let query: String?
            let pattern: String?
            let requirePattern: Bool
            let resultsCount: Int
            let totalMatches: Int
            let results: [HybridResultItem]
        }

        struct HybridResultItem: Codable {
            let score: Float
            let file: String
            let line: Int
            let name: String
            let kind: String
            let signature: String
            let layer: String
            let matchCount: Int
            let matchContext: String?
            let embeddingText: String
            let source: String
        }

        let totalMatches = results.filter { $0.matchCount > 0 }.count

        let items = results.map { result in
            HybridResultItem(
                score: result.score,
                file: result.chunk.file,
                line: result.chunk.line,
                name: result.chunk.name,
                kind: result.chunk.kind.rawValue,
                signature: result.chunk.signature,
                layer: result.chunk.layer,
                matchCount: result.matchCount,
                matchContext: result.matchContext,
                embeddingText: result.chunk.embeddingText,
                source: result.sourceLines.joined(separator: "\n")
            )
        }

        let report = HybridSearchReport(
            query: query,
            pattern: pattern,
            requirePattern: requirePattern,
            resultsCount: results.count,
            totalMatches: totalMatches,
            results: items
        )

        return encodeToJSON(report)
    }

    /// Get source code lines for a chunk (for pattern matching)
    private func getSourceForChunk(_ chunk: CodeChunk) -> [String] {
        // Try to get from cache first
        let filePath = chunk.file
        if let parsedFile = cache.getFile(filePath) {
            let lines = parsedFile.sourceText.components(separatedBy: "\n")
            let startLine = max(0, chunk.line - 1)
            let endLine = min(lines.count, chunk.line - 1 + chunk.lineCount)
            return Array(lines[startLine..<endLine])
        }

        // Fallback: try to read from project root
        let fullPath = projectRoot.appendingPathComponent(filePath)
        if let content = try? String(contentsOf: fullPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            let startLine = max(0, chunk.line - 1)
            let endLine = min(lines.count, chunk.line - 1 + chunk.lineCount)
            return Array(lines[startLine..<endLine])
        }

        return []
    }

    private func executeAnalyzeSwiftUI(path: String?) throws -> String {
        let cacheKey = "analyze_swiftui:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = SwiftUIAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeAnalyzeUIKit(path: String?) throws -> String {
        let cacheKey = "analyze_uikit:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = UIKitAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeAnalyzeTests() throws -> String {
        let cacheKey = "analyze_tests"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        // For tests, scan parent directory to find sibling test folders
        let parentURL = projectRoot.deletingLastPathComponent()
        let allFiles = findAllSwiftFiles(in: parentURL)
        let analyzer = TestCoverageAnalyzer()
        let report = analyzer.analyze(files: allFiles, relativeTo: parentURL, targetAnalysis: nil)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeAnalyzeDependencies() throws -> String {
        let cacheKey = "analyze_dependencies"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let analyzer = DependencyManagerAnalyzer()
        let report = analyzer.analyze(projectRoot: projectRoot)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeAnalyzeCoreData(path: String?) throws -> String {
        let cacheKey = "analyze_coredata:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = CoreDataAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeAnalyzeDocs(path: String?) throws -> String {
        let cacheKey = "analyze_docs:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = DocumentationAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeFindRetainCycles(path: String?) throws -> String {
        let cacheKey = "find_retain_cycles:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let parsedFiles = try getParsedFiles(for: path)
        let analyzer = RetainCycleAnalyzer()
        let report = analyzer.analyze(parsedFiles: parsedFiles)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
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
        let cacheKey = "analyze_api_surface:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let files = try getFiles(for: path)
        let analyzer = APIAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeGenerateMigrationChecklist() throws -> String {
        let cacheKey = "generate_migration_checklist"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let authAnalyzer = AuthMigrationAnalyzer()
        let authReport = authAnalyzer.analyze(files: cache.fileURLs, relativeTo: projectRoot)
        let generator = MigrationChecklistGenerator()
        let checklist = generator.generateAuthMigrationChecklist(from: authReport)
        let result = encodeToJSON(checklist)
        cache.cacheResult(result, for: cacheKey)
        return result
    }
    
    private func executeAnalyzeAuthMigration(path: String?) throws -> String {
        let cacheKey = "analyze_auth_migration:\(path ?? "all")"
        if let cached = cache.getCachedResult(for: cacheKey) {
            if verbose { fputs("[MCP] Cache hit: \(cacheKey)\n", stderr) }
            return cached
        }
        
        let files = try getFiles(for: path)
        let analyzer = AuthMigrationAnalyzer()
        let report = analyzer.analyze(files: files, relativeTo: projectRoot)
        let result = encodeToJSON(report)
        cache.cacheResult(result, for: cacheKey)
        return result
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
    
    // MARK: - DGX Server Tools

    private func executeDGXHealth(endpoint: String) throws -> String {
        guard let baseURL = URL(string: endpoint) else {
            throw NSError(domain: "DGX", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid DGX endpoint URL: \(endpoint)"
            ])
        }
        let healthURL = baseURL.deletingLastPathComponent().appendingPathComponent("health")
        return try fetchDGXEndpoint(url: healthURL, description: "health")
    }

    private func executeDGXStats(endpoint: String) throws -> String {
        guard let baseURL = URL(string: endpoint) else {
            throw NSError(domain: "DGX", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid DGX endpoint URL: \(endpoint)"
            ])
        }
        let statsURL = baseURL.deletingLastPathComponent().appendingPathComponent("stats")
        return try fetchDGXEndpoint(url: statsURL, description: "stats")
    }

    private func fetchDGXEndpoint(url: URL, description: String) throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10  // Quick timeout for health checks

        var result: String?
        var error: Error?

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, err in
            defer { semaphore.signal() }

            if let err = err {
                error = NSError(domain: "DGX", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "DGX server unreachable: \(err.localizedDescription)"
                ])
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                error = NSError(domain: "DGX", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response from DGX server"
                ])
                return
            }

            guard httpResponse.statusCode == 200 else {
                error = NSError(domain: "DGX", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "DGX server returned HTTP \(httpResponse.statusCode)"
                ])
                return
            }

            guard let data = data, let json = String(data: data, encoding: .utf8) else {
                error = NSError(domain: "DGX", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "No data from DGX server"
                ])
                return
            }

            result = json
        }
        task.resume()
        semaphore.wait()

        if let error = error {
            throw error
        }

        return result ?? "{\"error\": \"unknown\"}"
    }

    private func executeIndexingStatus() -> String {
        struct IndexingStatus: Codable {
            let status: String           // idle, indexing, complete, error
            let progress: Int            // 0-100 percentage
            let current: Int             // chunks embedded so far
            let total: Int               // total chunks to embed
            let elapsedSeconds: Double?  // time since indexing started
            let etaSeconds: Double?      // estimated time remaining
            let chunksPerSecond: Double? // embedding throughput
            let provider: String?        // dgx or nlembedding
            let batchSize: Int?          // current batch size
            let error: String?           // error message if failed
            let indexSize: Int           // total chunks in index
        }

        indexingLock.lock()
        let isCurrentlyIndexing = isIndexing
        let progress = indexingProgress
        let errorMsg = indexingError
        let startTime = indexingStartTime
        let endTime = indexingEndTime
        let provider = indexingProvider
        let batchSize = indexingBatchSize
        indexingLock.unlock()

        let indexSize = embeddingIndex?.count ?? 0

        // Calculate timing
        var elapsed: Double? = nil
        var eta: Double? = nil
        var rate: Double? = nil

        if let start = startTime {
            let end = endTime ?? Date()
            let elapsedTime = end.timeIntervalSince(start)
            elapsed = elapsedTime

            if isCurrentlyIndexing && progress.0 > 0 && progress.1 > 0 {
                let secondsPerChunk = elapsedTime / Double(progress.0)
                let remaining = progress.1 - progress.0
                eta = secondsPerChunk * Double(remaining)
                rate = Double(progress.0) / elapsedTime
            } else if !isCurrentlyIndexing && progress.1 > 0 {
                rate = Double(progress.1) / elapsedTime
            }
        }

        // Determine status string
        let statusStr: String
        if let _ = errorMsg {
            statusStr = "error"
        } else if isCurrentlyIndexing {
            statusStr = "indexing"
        } else if indexSize > 0 {
            statusStr = "complete"
        } else {
            statusStr = "idle"
        }

        let percent = progress.1 > 0 ? (progress.0 * 100 / progress.1) : 0

        let status = IndexingStatus(
            status: statusStr,
            progress: percent,
            current: progress.0,
            total: progress.1,
            elapsedSeconds: elapsed.map { round($0 * 10) / 10 },
            etaSeconds: eta.map { round($0 * 10) / 10 },
            chunksPerSecond: rate.map { round($0 * 10) / 10 },
            provider: provider.isEmpty ? nil : provider,
            batchSize: batchSize > 0 ? batchSize : nil,
            error: errorMsg,
            indexSize: indexSize
        )

        return encodeToJSON(status)
    }

    // MARK: - Build and Test Tools

    struct BuildResult: Codable {
        let success: Bool
        let duration: Double
        let configuration: String
        let errors: [BuildIssue]
        let warnings: [BuildIssue]
        let rawOutput: String?
    }

    struct BuildIssue: Codable {
        let file: String
        let line: Int
        let column: Int?
        let message: String
        let suggestion: String?
    }

    struct TestRunResult: Codable {
        let success: Bool
        let duration: Double
        let passed: Int
        let failed: Int
        let skipped: Int
        let total: Int
        let noTestsFound: Bool
        let tests: [TestResult]
        let rawOutput: String?
    }

    struct TestResult: Codable {
        let name: String
        let status: String
        let duration: Double?
        let message: String?
    }

    private func executeBuildAndCheck(release: Bool, clean: Bool) -> String {
        let startTime = Date()
        var commands: [String] = []

        // Clean if requested
        if clean {
            commands.append("swift package clean")
        }

        // Build command
        let config = release ? "-c release" : ""
        commands.append("swift build \(config) 2>&1")

        let fullCommand = commands.joined(separator: " && ")

        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", fullCommand]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            struct ErrorResult: Codable { let error: String }
            return encodeToJSON(ErrorResult(error: "Failed to run build: \(error.localizedDescription)"))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let duration = Date().timeIntervalSince(startTime)
        let success = process.terminationStatus == 0

        // Parse errors and warnings
        var errors: [BuildIssue] = []
        var warnings: [BuildIssue] = []

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            // Swift error format: /path/file.swift:123:45: error: message
            // Also: /path/file.swift:123: error: message (no column)
            let errorPattern = #"(.+\.swift):(\d+):(?:(\d+):)?\s*(error|warning):\s*(.+)"#
            if let regex = try? NSRegularExpression(pattern: errorPattern, options: []),
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {

                let filePath = line[Range(match.range(at: 1), in: line)!]
                let lineNum = Int(line[Range(match.range(at: 2), in: line)!]) ?? 0
                let column = match.range(at: 3).location != NSNotFound
                    ? Int(line[Range(match.range(at: 3), in: line)!])
                    : nil
                let issueType = line[Range(match.range(at: 4), in: line)!]
                let message = String(line[Range(match.range(at: 5), in: line)!])

                // Make path relative to project root
                let relativePath = String(filePath).replacingOccurrences(of: projectRoot.path + "/", with: "")

                let issue = BuildIssue(
                    file: relativePath,
                    line: lineNum,
                    column: column,
                    message: message,
                    suggestion: suggestFix(for: message)
                )

                if issueType == "error" {
                    errors.append(issue)
                } else {
                    warnings.append(issue)
                }
            }
        }

        let result = BuildResult(
            success: success,
            duration: round(duration * 100) / 100,
            configuration: release ? "release" : "debug",
            errors: errors,
            warnings: warnings,
            rawOutput: success ? nil : output  // Include raw output only on failure
        )

        return encodeToJSON(result)
    }

    private func suggestFix(for message: String) -> String? {
        // Common Swift error patterns and suggestions
        if message.contains("cannot convert value of type") && message.contains("Optional") {
            return "Use optional binding (if let/guard let) or nil coalescing (??) to unwrap"
        }
        if message.contains("value of optional type") && message.contains("not unwrapped") {
            return "Add '?' for optional chaining or '!' for force unwrap (unsafe)"
        }
        if message.contains("cannot find") && message.contains("in scope") {
            return "Check spelling, add import, or ensure the type/function is accessible"
        }
        if message.contains("missing argument") {
            return "Add the missing required parameter"
        }
        if message.contains("extra argument") {
            return "Remove the extra parameter or check function signature"
        }
        if message.contains("type annotation missing") {
            return "Add explicit type annotation"
        }
        if message.contains("ambiguous use of") {
            return "Add explicit type annotation to resolve ambiguity"
        }
        if message.contains("protocol") && message.contains("requires") {
            return "Implement the missing protocol requirement"
        }
        if message.contains("initializer") && message.contains("inaccessible") {
            return "Use a public initializer or make the type's init accessible"
        }
        return nil
    }

    private func executeRunTests(filter: String?, verbose: Bool) -> String {
        let startTime = Date()

        // Build test command
        var command = "swift test"
        if let filter = filter {
            command += " --filter '\(filter)'"
        }
        command += " 2>&1"

        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            struct ErrorResult: Codable { let error: String }
            return encodeToJSON(ErrorResult(error: "Failed to run tests: \(error.localizedDescription)"))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let duration = Date().timeIntervalSince(startTime)
        let success = process.terminationStatus == 0

        // Parse test results
        var tests: [TestResult] = []
        var passed = 0
        var failed = 0
        var skipped = 0

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            // Swift Testing format: ✔ Test name passed
            // Swift Testing format: ✘ Test name failed
            // XCTest format: Test Case '-[TestClass testMethod]' passed (0.001 seconds)

            // Swift Testing pass
            if line.contains("✔") || line.contains("passed") {
                let testName = extractTestName(from: line)
                if !testName.isEmpty {
                    tests.append(TestResult(name: testName, status: "passed", duration: nil, message: nil))
                    passed += 1
                }
            }
            // Swift Testing fail
            else if line.contains("✘") || (line.contains("failed") && !line.contains("tests failed")) {
                let testName = extractTestName(from: line)
                if !testName.isEmpty {
                    tests.append(TestResult(name: testName, status: "failed", duration: nil, message: extractFailureMessage(from: lines, testName: testName)))
                    failed += 1
                }
            }
            // Skipped
            else if line.contains("skipped") {
                let testName = extractTestName(from: line)
                if !testName.isEmpty {
                    tests.append(TestResult(name: testName, status: "skipped", duration: nil, message: nil))
                    skipped += 1
                }
            }
        }

        // Check if no tests found
        let noTests = output.contains("no tests found") || output.contains("0 tests")

        let result = TestRunResult(
            success: success && !noTests,
            duration: round(duration * 100) / 100,
            passed: passed,
            failed: failed,
            skipped: skipped,
            total: passed + failed + skipped,
            noTestsFound: noTests,
            tests: verbose ? tests : tests.filter { $0.status == "failed" },
            rawOutput: verbose ? output : nil
        )

        return encodeToJSON(result)
    }

    private func extractTestName(from line: String) -> String {
        // Try to extract test name from various formats
        var name = line
            .replacingOccurrences(of: "✔", with: "")
            .replacingOccurrences(of: "✘", with: "")
            .replacingOccurrences(of: "Test Case", with: "")
            .replacingOccurrences(of: "passed", with: "")
            .replacingOccurrences(of: "failed", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Remove timing info like "(0.001 seconds)"
        if let parenRange = name.range(of: #"\s*\([^)]+\)\s*$"#, options: .regularExpression) {
            name = String(name[..<parenRange.lowerBound])
        }

        return name.trimmingCharacters(in: .whitespaces)
    }

    private func extractFailureMessage(from lines: [String], testName: String) -> String? {
        // Look for assertion failure messages after the test name
        var capture = false
        var messages: [String] = []

        for line in lines {
            if line.contains(testName) && (line.contains("✘") || line.contains("failed")) {
                capture = true
                continue
            }
            if capture {
                if line.contains("✔") || line.contains("✘") || line.isEmpty {
                    break
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    messages.append(trimmed)
                }
            }
        }

        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func encodeToJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        // Use compact JSON (no pretty printing) for faster transfer to AI agents
        // sortedKeys helps with caching consistency
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"encoding_failed\"}"
        }
        return string
    }
}

// MARK: - Server Entry Point

func runMCPServer(projectPath: String?, verbose: Bool) {
    let projectURL = projectPath.map { URL(fileURLWithPath: $0) }
    let server = MCPServer(projectRoot: projectURL, verbose: verbose)
    server.run()
}
