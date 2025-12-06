import Foundation
import SwiftSyntax
import SwiftParser

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
    
    public init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    /// Get all cached file URLs
    public var fileURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return files.values.map { $0.url }
    }
    
    /// Get all parsed files
    public var parsedFiles: [ParsedFile] {
        lock.lock()
        defer { lock.unlock() }
        return Array(files.values)
    }
    
    /// Get file count
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
    
    /// Get files matching a path filter
    public func getFiles(matching filter: String?) -> [ParsedFile] {
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
