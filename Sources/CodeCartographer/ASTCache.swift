import Foundation
import SwiftSyntax
import SwiftParser
import CoreServices

// MARK: - Parsed File

/// A file with its source text and lazily-parsed AST
public final class ParsedFile {
    public let url: URL
    public let relativePath: String
    public let sourceText: String
    public let contentHash: String
    
    private var _ast: SourceFileSyntax?
    private let lock = NSLock()
    
    public var ast: SourceFileSyntax {
        lock.lock()
        defer { lock.unlock() }
        
        if _ast == nil {
            _ast = Parser.parse(source: sourceText)
        }
        return _ast!
    }
    
    /// Check if AST has been parsed (without triggering parse)
    public var isParsed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _ast != nil
    }
    
    public init(url: URL, relativeTo root: URL) throws {
        self.url = url
        self.relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
        self.sourceText = try String(contentsOf: url)
        
        // Fast hash for change detection
        let data = sourceText.data(using: .utf8) ?? Data()
        self.contentHash = String(data.hashValue, radix: 16)
    }
    
    /// Create with pre-parsed AST (for testing or when AST already exists)
    public init(url: URL, relativePath: String, sourceText: String, ast: SourceFileSyntax? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.sourceText = sourceText
        self._ast = ast
        
        let data = sourceText.data(using: .utf8) ?? Data()
        self.contentHash = String(data.hashValue, radix: 16)
    }
}

// MARK: - AST Cache

/// Manages a cache of parsed files with lazy AST parsing and change detection
public final class ASTCache {
    private var files: [String: ParsedFile] = [:]  // relativePath -> ParsedFile
    private let lock = NSLock()
    
    public let rootURL: URL
    public private(set) var lastScanTime: Date?
    private var hasScanned = false  // Track if initial scan completed
    
    // File watching
    private var fileWatcher: FileWatcher?
    private var pendingInvalidations: Set<String> = []
    private var debounceWorkItem: DispatchWorkItem?
    public var verbose: Bool = false
    
    /// Callback when files change (for incremental re-embedding)
    /// Set<String> contains relative paths of changed/added/deleted files
    public var onFilesChanged: ((Set<String>) -> Void)?
    
    // Result caching - stores tool results keyed by tool name
    // Invalidated when any file changes
    private var resultCache: [String: String] = [:]  // toolKey -> JSON result
    private var resultCacheValid = false
    private let resultLock = NSLock()
    
    // Per-file analyzer findings cache
    // Key: relativePath, Value: (contentHash, findings)
    // Only valid if contentHash matches current file
    private var findingsCache: [String: (hash: String, findings: FileFindings)] = [:]
    private let findingsLock = NSLock()
    
    // Per-file chunks cache
    // Key: relativePath, Value: (contentHash, chunks)
    private var chunksCache: [String: (hash: String, chunks: [CodeChunk])] = [:]
    private let chunksLock = NSLock()
    
    // Per-chunk embedding cache
    // Key: chunk.id + contentHash, Value: embedding vector
    private var embeddingCache: [String: [Float]] = [:]
    private let embeddingLock = NSLock()
    
    public init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    /// Ensure initial scan has completed before accessing files
    private func ensureScanned() {
        if !hasScanned {
            scan(verbose: verbose)
        }
    }
    
    deinit {
        stopWatching()
    }
    
    /// Get all cached file URLs (auto-scans if needed)
    public var fileURLs: [URL] {
        ensureScanned()
        lock.lock()
        defer { lock.unlock() }
        return files.values.map { $0.url }
    }
    
    /// Get all parsed files (auto-scans if needed)
    public var parsedFiles: [ParsedFile] {
        ensureScanned()
        lock.lock()
        defer { lock.unlock() }
        return Array(files.values)
    }
    
    /// Get file count (does NOT auto-scan - used to check if scan needed)
    public var fileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return files.count
    }
    
    /// Scan directory for Swift files and update cache
    @discardableResult
    public func scan(verbose: Bool = false) -> Int {
        let startTime = Date()
        let swiftFiles = findSwiftFiles(in: rootURL)
        
        lock.lock()
        defer { lock.unlock() }
        
        var newCount = 0
        var unchangedCount = 0
        var updatedCount = 0
        
        // Track which files still exist
        var existingPaths = Set(files.keys)
        
        for url in swiftFiles {
            let relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            existingPaths.remove(relativePath)
            
            // Check if file exists in cache
            if let existing = files[relativePath] {
                // Check if file changed by comparing hash
                if let newText = try? String(contentsOf: url) {
                    let newData = newText.data(using: .utf8) ?? Data()
                    let newHash = String(newData.hashValue, radix: 16)
                    
                    if newHash == existing.contentHash {
                        unchangedCount += 1
                        continue  // File unchanged, keep cached version
                    } else {
                        // File changed, update cache
                        if let parsed = try? ParsedFile(url: url, relativeTo: rootURL) {
                            files[relativePath] = parsed
                            updatedCount += 1
                        }
                    }
                }
            } else {
                // New file, add to cache
                if let parsed = try? ParsedFile(url: url, relativeTo: rootURL) {
                    files[relativePath] = parsed
                    newCount += 1
                }
            }
        }
        
        // Remove deleted files
        let deletedCount = existingPaths.count
        for path in existingPaths {
            files.removeValue(forKey: path)
        }
        
        lastScanTime = Date()
        hasScanned = true
        
        if verbose {
            let elapsed = Date().timeIntervalSince(startTime)
            fputs("[Cache] Scanned in \(String(format: "%.2f", elapsed))s: \(files.count) files (\(newCount) new, \(updatedCount) updated, \(unchangedCount) cached, \(deletedCount) deleted)\n", stderr)
        }
        
        return files.count
    }
    
    /// Get a parsed file by relative path
    public func getFile(_ relativePath: String) -> ParsedFile? {
        lock.lock()
        defer { lock.unlock() }
        return files[relativePath]
    }
    
    /// Get files matching a path filter (auto-scans if needed)
    public func getFiles(matching filter: String?) -> [ParsedFile] {
        ensureScanned()
        lock.lock()
        defer { lock.unlock() }
        
        if let filter = filter {
            return files.values.filter { 
                $0.relativePath.contains(filter) || $0.url.lastPathComponent == filter
            }
        }
        return Array(files.values)
    }
    
    /// Invalidate a specific file (will be re-parsed on next access)
    public func invalidate(_ relativePath: String) {
        lock.lock()
        defer { lock.unlock() }
        files.removeValue(forKey: relativePath)
    }
    
    /// Invalidate all files
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        files.removeAll()
    }
    
    /// Get cache statistics
    public var stats: (total: Int, parsed: Int, unparsed: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        let parsed = files.values.filter { $0.isParsed }.count
        return (files.count, parsed, files.count - parsed)
    }
    
    // MARK: - Result Caching
    
    /// Get cached result for a tool call
    public func getCachedResult(for key: String) -> String? {
        resultLock.lock()
        defer { resultLock.unlock() }
        
        guard resultCacheValid else { return nil }
        return resultCache[key]
    }
    
    /// Cache a result for a tool call
    public func cacheResult(_ result: String, for key: String) {
        resultLock.lock()
        defer { resultLock.unlock() }
        
        resultCache[key] = result
        resultCacheValid = true
    }
    
    /// Invalidate all cached results (called when files change)
    public func invalidateResults() {
        resultLock.lock()
        defer { resultLock.unlock() }
        
        if !resultCache.isEmpty && verbose {
            fputs("[Cache] Invalidated \(resultCache.count) cached results\n", stderr)
        }
        resultCache.removeAll()
        resultCacheValid = false
    }
    
    // MARK: - Per-File Analyzer Findings Cache
    
    /// Get cached findings for a file (returns nil if not cached or file changed)
    public func getFindings(for file: ParsedFile) -> FileFindings? {
        findingsLock.lock()
        defer { findingsLock.unlock() }
        
        guard let cached = findingsCache[file.relativePath],
              cached.hash == file.contentHash else {
            return nil
        }
        return cached.findings
    }
    
    /// Cache findings for a file
    public func cacheFindings(_ findings: FileFindings, for file: ParsedFile) {
        findingsLock.lock()
        defer { findingsLock.unlock() }
        
        findingsCache[file.relativePath] = (file.contentHash, findings)
    }
    
    /// Get findings cache stats
    public var findingsCacheStats: (cached: Int, total: Int) {
        findingsLock.lock()
        defer { findingsLock.unlock() }
        return (findingsCache.count, files.count)
    }
    
    /// Clear findings cache (called when project changes)
    public func invalidateFindingsCache() {
        findingsLock.lock()
        defer { findingsLock.unlock() }
        findingsCache.removeAll()
    }
    
    // MARK: - Per-File Chunks Cache
    
    /// Get cached chunks for a file
    public func getChunks(for file: ParsedFile) -> [CodeChunk]? {
        chunksLock.lock()
        defer { chunksLock.unlock() }
        
        guard let cached = chunksCache[file.relativePath],
              cached.hash == file.contentHash else {
            return nil
        }
        return cached.chunks
    }
    
    /// Cache chunks for a file
    public func cacheChunks(_ chunks: [CodeChunk], for file: ParsedFile) {
        chunksLock.lock()
        defer { chunksLock.unlock() }
        
        chunksCache[file.relativePath] = (file.contentHash, chunks)
    }
    
    // MARK: - Embedding Cache
    
    /// Get cached embedding for a chunk
    public func getEmbedding(for chunkId: String, contentHash: String) -> [Float]? {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        
        let key = "\(chunkId):\(contentHash)"
        return embeddingCache[key]
    }
    
    /// Cache embedding for a chunk
    public func cacheEmbedding(_ embedding: [Float], for chunkId: String, contentHash: String) {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        
        let key = "\(chunkId):\(contentHash)"
        embeddingCache[key] = embedding
    }
    
    /// Get embedding cache stats
    public var embeddingCacheCount: Int {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        return embeddingCache.count
    }
    
    /// Clear all chunk-related caches
    public func invalidateChunkCaches() {
        chunksLock.lock()
        chunksCache.removeAll()
        chunksLock.unlock()
        
        embeddingLock.lock()
        embeddingCache.removeAll()
        embeddingLock.unlock()
    }
    
    // MARK: - Parallel Parsing
    
    /// Pre-parse all ASTs in parallel for faster first tool call
    /// Uses batched processing to reduce thread overhead
    public func warmCache(verbose: Bool = false) {
        let startTime = Date()
        let filesToParse = parsedFiles.filter { !$0.isParsed }
        
        guard !filesToParse.isEmpty else {
            if verbose {
                fputs("[Cache] Already warm (\(files.count) files parsed)\n", stderr)
            }
            return
        }
        
        // Batch files for parallel processing to reduce thread overhead
        // Use ~2x CPU cores worth of batches for good parallelism
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let batchSize = max(10, filesToParse.count / (coreCount * 2))
        let batches = stride(from: 0, to: filesToParse.count, by: batchSize).map {
            Array(filesToParse[$0..<min($0 + batchSize, filesToParse.count)])
        }
        
        let parseQueue = DispatchQueue(label: "com.codecartographer.parse", attributes: .concurrent)
        let group = DispatchGroup()
        
        // Process batches in parallel, files within batch sequentially
        for batch in batches {
            group.enter()
            parseQueue.async {
                for file in batch {
                    _ = file.ast  // Trigger lazy parse
                }
                group.leave()
            }
        }
        
        group.wait()
        
        if verbose {
            let elapsed = Date().timeIntervalSince(startTime)
            fputs("[Cache] Warmed in \(String(format: "%.2f", elapsed))s: \(filesToParse.count) files in \(batches.count) batches\n", stderr)
        }
    }
    
    // MARK: - File Watching
    
    /// Start watching for file changes
    public func startWatching() {
        guard fileWatcher == nil else { return }
        
        fileWatcher = FileWatcher(directory: rootURL) { [weak self] event in
            self?.handleFileEvent(event)
        }
        fileWatcher?.start()
        
        if verbose {
            fputs("[Cache] Started watching \(rootURL.path)\n", stderr)
        }
    }
    
    /// Stop watching for file changes
    public func stopWatching() {
        fileWatcher?.stop()
        fileWatcher = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }
    
    /// Handle a file system event
    private func handleFileEvent(_ event: FileWatcher.Event) {
        let path = event.path
        
        // Only care about Swift files
        guard path.hasSuffix(".swift") else { return }
        
        // Get relative path
        let relativePath = path.replacingOccurrences(of: rootURL.path + "/", with: "")
        
        // Skip hidden files and build directories
        if relativePath.hasPrefix(".") || 
           relativePath.contains("/.") ||
           relativePath.contains(".build/") ||
           relativePath.contains("DerivedData/") ||
           relativePath.contains("Pods/") {
            return
        }
        
        lock.lock()
        pendingInvalidations.insert(relativePath)
        lock.unlock()
        
        // Debounce: wait 100ms for more changes before processing
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.processPendingInvalidations()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
    
    /// Process pending invalidations after debounce
    private func processPendingInvalidations() {
        lock.lock()
        let paths = pendingInvalidations
        pendingInvalidations.removeAll()
        lock.unlock()
        
        guard !paths.isEmpty else { return }
        
        // Invalidate cached results since files changed
        invalidateResults()
        
        for relativePath in paths {
            let url = rootURL.appendingPathComponent(relativePath)
            
            // Check if file was deleted or modified
            if FileManager.default.fileExists(atPath: url.path) {
                // File modified or created - update cache
                if let parsed = try? ParsedFile(url: url, relativeTo: rootURL) {
                    lock.lock()
                    let wasNew = files[relativePath] == nil
                    files[relativePath] = parsed
                    lock.unlock()
                    
                    if verbose {
                        let action = wasNew ? "Added" : "Updated"
                        fputs("[Cache] \(action): \(relativePath)\n", stderr)
                    }
                }
            } else {
                // File deleted - remove from cache
                lock.lock()
                files.removeValue(forKey: relativePath)
                lock.unlock()
                
                if verbose {
                    fputs("[Cache] Removed: \(relativePath)\n", stderr)
                }
            }
        }
        
        // Notify listener of changed files (for incremental re-embedding)
        onFilesChanged?(paths)
    }
}

// MARK: - File Watcher

/// Simple file system watcher using FSEvents
final class FileWatcher {
    enum Event {
        case modified(path: String)
        case created(path: String)
        case deleted(path: String)
        
        var path: String {
            switch self {
            case .modified(let p), .created(let p), .deleted(let p):
                return p
            }
        }
    }
    
    private let directory: URL
    private let callback: (Event) -> Void
    private var stream: FSEventStreamRef?
    
    init(directory: URL, callback: @escaping (Event) -> Void) {
        self.directory = directory
        self.callback = callback
    }
    
    private let queue = DispatchQueue(label: "com.codecartographer.filewatcher", qos: .utility)
    
    func start() {
        let paths = [directory.path] as CFArray
        
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | 
                          kFSEventStreamCreateFlagFileEvents |
                          kFSEventStreamCreateFlagNoDefer)
        
        stream = FSEventStreamCreate(
            nil,
            { (streamRef, clientCallbackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info = clientCallbackInfo else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                
                guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
                
                for i in 0..<numEvents {
                    let path = paths[i]
                    let flags = eventFlags[i]
                    
                    let event: Event
                    if (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 {
                        event = .deleted(path: path)
                    } else if (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 {
                        event = .created(path: path)
                    } else {
                        event = .modified(path: path)
                    }
                    
                    watcher.callback(event)
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // 100ms latency
            flags
        )
        
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }
    
    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

// MARK: - Analyzer Protocol Extension

/// Protocol for analyzers that can use cached ASTs
public protocol CachingAnalyzer {
    associatedtype Report
    
    /// Analyze using pre-parsed files (efficient for MCP server)
    func analyze(parsedFiles: [ParsedFile]) -> Report
    
    /// Analyze using file URLs (convenience for CLI, parses on-the-fly)
    func analyze(files: [URL], relativeTo root: URL) -> Report
}

/// Default implementation that bridges URL-based analysis to ParsedFile-based
extension CachingAnalyzer {
    public func analyze(files: [URL], relativeTo root: URL) -> Report {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
