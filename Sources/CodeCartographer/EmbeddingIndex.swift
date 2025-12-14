import Foundation

// MARK: - Embedding Index

/// In-memory index for semantic search over code chunks
/// Thread-safe: uses reader-writer lock for concurrent reads, exclusive writes
final class EmbeddingIndex {
    /// Current schema version - increment when cache format changes
    static var currentSchemaVersion: Int { kIndexSchemaVersion }

    let provider: EmbeddingProvider
    let verbose: Bool

    private var embeddings: [[Float]] = []
    private var chunkIds: [String] = []
    private var chunks: [String: CodeChunk] = [:]  // id -> chunk
    private var fileHashes: [String: String] = [:]  // file -> contentHash (for change detection)

    // Reader-writer lock: allows concurrent reads, exclusive writes
    private var rwLock = pthread_rwlock_t()

    var count: Int {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return embeddings.count
    }

    var isEmpty: Bool {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return embeddings.isEmpty
    }

    init(provider: EmbeddingProvider, verbose: Bool = false) {
        self.provider = provider
        self.verbose = verbose
        pthread_rwlock_init(&rwLock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&rwLock)
    }

    /// Set file hashes for embedding cache keys
    func setFileHashes(_ hashes: [String: String]) {
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        self.fileHashes = hashes
    }
    
    // MARK: - Indexing

    /// Index a batch of chunks
    /// Embeddings are computed via the provider and stored in-memory
    /// Persistence is handled by save/load methods
    func index(_ newChunks: [CodeChunk]) throws {
        guard !newChunks.isEmpty else { return }

        // Compute embeddings (expensive, no lock held)
        let texts = newChunks.map { $0.embeddingText }
        let newEmbeddings = try provider.embed(texts)

        // Store results (write lock)
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        for (i, chunk) in newChunks.enumerated() {
            embeddings.append(newEmbeddings[i])
            chunkIds.append(chunk.id)
            chunks[chunk.id] = chunk
        }
    }

    /// Clear the index
    func clear() {
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        embeddings = []
        chunkIds = []
        chunks = [:]
    }
    
    /// Remove all chunks belonging to specific files
    /// Returns the number of chunks removed
    @discardableResult
    func removeChunksForFiles(_ files: Set<String>) -> Int {
        guard !files.isEmpty else { return 0 }

        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }

        // Find indices to remove (in reverse order for safe removal)
        var indicesToRemove: [Int] = []
        for (i, chunkId) in chunkIds.enumerated() {
            if let chunk = chunks[chunkId], files.contains(chunk.file) {
                indicesToRemove.append(i)
            }
        }

        // Remove in reverse order to maintain valid indices
        for i in indicesToRemove.reversed() {
            let chunkId = chunkIds[i]
            embeddings.remove(at: i)
            chunkIds.remove(at: i)
            chunks.removeValue(forKey: chunkId)
        }

        if verbose && !indicesToRemove.isEmpty {
            fputs("[EmbeddingIndex] Removed \(indicesToRemove.count) chunks for \(files.count) changed files\n", stderr)
        }

        return indicesToRemove.count
    }

    /// Virtual chunk kinds that aggregate data across files
    private static let virtualChunkKinds: Set<CodeChunk.ChunkKind> = [.hotspot, .fileSummary, .cluster, .typeSummary]

    /// Remove all virtual chunks (hotspots, summaries, clusters, typeSummaries)
    /// These need to be regenerated when any file changes
    /// Returns the number of chunks removed
    @discardableResult
    func removeVirtualChunks() -> Int {
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }

        var indicesToRemove: [Int] = []
        for (i, chunkId) in chunkIds.enumerated() {
            if let chunk = chunks[chunkId], Self.virtualChunkKinds.contains(chunk.kind) {
                indicesToRemove.append(i)
            }
        }

        for i in indicesToRemove.reversed() {
            let chunkId = chunkIds[i]
            embeddings.remove(at: i)
            chunkIds.remove(at: i)
            chunks.removeValue(forKey: chunkId)
        }

        if verbose && !indicesToRemove.isEmpty {
            fputs("[EmbeddingIndex] Removed \(indicesToRemove.count) virtual chunks\n", stderr)
        }

        return indicesToRemove.count
    }

    /// Get all file-level chunks (non-virtual) for regenerating virtual chunks
    func getFileChunks() -> [CodeChunk] {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return chunks.values.filter { !Self.virtualChunkKinds.contains($0.kind) }
    }

    /// Update file hashes for changed files
    func updateFileHashes(_ hashes: [String: String]) {
        pthread_rwlock_wrlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        for (file, hash) in hashes {
            fileHashes[file] = hash
        }
    }
    
    // MARK: - Search

    /// Search for chunks similar to the query
    func search(query: String, topK: Int = 10) throws -> [SearchResult] {
        guard !isEmpty else { return [] }

        // Embed query (expensive, no lock needed)
        let queryEmbedding = try provider.embed(query)

        // Search with the embedded vector
        return search(queryVector: queryEmbedding, topK: topK)
    }

    /// Search with a pre-embedded query vector
    func search(queryVector: [Float], topK: Int = 10) -> [SearchResult] {
        pthread_rwlock_rdlock(&rwLock)

        // Take snapshots under lock
        let embeddingsSnapshot = embeddings
        let chunkIdsSnapshot = chunkIds
        let chunksSnapshot = chunks

        pthread_rwlock_unlock(&rwLock)

        guard !embeddingsSnapshot.isEmpty else { return [] }

        // Compute similarities (no lock held)
        var scores: [(index: Int, score: Float)] = []
        for (i, embedding) in embeddingsSnapshot.enumerated() {
            let score = cosineSimilarity(queryVector, embedding)
            scores.append((i, score))
        }

        // Sort by score descending
        scores.sort { $0.score > $1.score }

        // Return top K
        return scores.prefix(topK).compactMap { item in
            let chunkId = chunkIdsSnapshot[item.index]
            guard let chunk = chunksSnapshot[chunkId] else { return nil }
            return SearchResult(chunk: chunk, score: item.score)
        }
    }
    
    /// Find chunks similar to an existing chunk by its ID
    func similarTo(chunkId: String, topK: Int = 10) -> [SearchResult] {
        pthread_rwlock_rdlock(&rwLock)
        guard let index = chunkIds.firstIndex(of: chunkId) else {
            pthread_rwlock_unlock(&rwLock)
            return []
        }
        let embedding = embeddings[index]
        pthread_rwlock_unlock(&rwLock)

        // Search excluding self (search() handles its own locking)
        return search(queryVector: embedding, topK: topK + 1)
            .filter { $0.chunk.id != chunkId }
            .prefix(topK)
            .map { $0 }
    }

    /// Get the embedding vector for a chunk
    func getEmbedding(for chunkId: String) -> [Float]? {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        guard let index = chunkIds.firstIndex(of: chunkId) else { return nil }
        return embeddings[index]
    }

    /// Get a chunk by ID
    func getChunk(_ chunkId: String) -> CodeChunk? {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return chunks[chunkId]
    }

    /// Get all chunk IDs currently in the index
    func getAllChunkIds() -> [String] {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return chunkIds
    }

    // MARK: - Persistence

    /// Save index to disk with cross-process file locking
    /// - Parameters:
    ///   - url: Cache file URL
    ///   - isComplete: true if full indexing finished, false for checkpoint saves
    ///   - totalExpectedChunks: total chunks expected when complete (for progress tracking)
    ///   - dgxJobId: active DGX job ID to store for resume (nil clears it)
    func save(to url: URL, isComplete: Bool = true, totalExpectedChunks: Int? = nil, dgxJobId: String? = nil) throws {
        // Snapshot data under read lock
        pthread_rwlock_rdlock(&rwLock)
        let data = IndexData(
            schemaVersion: kIndexSchemaVersion,
            embeddings: embeddings,
            chunkIds: chunkIds,
            chunks: Array(chunks.values),
            providerName: provider.name,
            dimensions: provider.dimensions,
            fileHashes: fileHashes,
            timestamp: Date(),
            isComplete: isComplete,
            totalExpectedChunks: totalExpectedChunks ?? embeddings.count,
            dgxJobId: dgxJobId
        )
        let count = embeddings.count
        pthread_rwlock_unlock(&rwLock)

        // Encode first (before acquiring lock)
        let encoded = try JSONEncoder().encode(data)

        // Acquire exclusive file lock for cross-process safety
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: "EmbeddingIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open cache file for writing"])
        }
        defer { close(fd) }

        // Exclusive lock (blocks until acquired)
        guard flock(fd, LOCK_EX) == 0 else {
            throw NSError(domain: "EmbeddingIndex", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to acquire exclusive lock on cache file"])
        }
        defer { flock(fd, LOCK_UN) }

        // Write data
        try encoded.withUnsafeBytes { ptr in
            let written = write(fd, ptr.baseAddress, ptr.count)
            guard written == ptr.count else {
                throw NSError(domain: "EmbeddingIndex", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write cache file"])
            }
        }

        if verbose {
            let sizeMB = Double(encoded.count) / 1_000_000
            fputs("[EmbeddingIndex] Saved \(count) embeddings (\(String(format: "%.1f", sizeMB)) MB) to \(url.lastPathComponent)\n", stderr)
        }
    }

    /// Result of loading cache
    struct LoadResult {
        let changedFiles: Set<String>  // Files that need re-embedding
        let wasComplete: Bool  // Was the cache from a complete indexing run?
        let totalExpectedChunks: Int?  // Total chunks expected if known
        let dgxJobId: String?  // Active DGX job ID if checkpoint was mid-indexing
    }

    /// Load index from disk with cross-process file locking
    /// Returns LoadResult with changed files and completion status
    func load(from url: URL, currentHashes: [String: String]) throws -> LoadResult {
        // Acquire shared file lock for cross-process safety
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: "EmbeddingIndex", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to open cache file for reading"])
        }
        defer { close(fd) }

        // Shared lock (allows multiple readers, blocks writers)
        guard flock(fd, LOCK_SH) == 0 else {
            throw NSError(domain: "EmbeddingIndex", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to acquire shared lock on cache file"])
        }
        defer { flock(fd, LOCK_UN) }

        // Read with lock held
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(IndexData.self, from: data)

        // Verify schema version matches (chunk extraction logic may have changed)
        let cacheVersion = decoded.schemaVersion ?? 0  // Old caches have no version
        guard cacheVersion == kIndexSchemaVersion else {
            throw IndexError.schemaVersionMismatch(
                expected: kIndexSchemaVersion,
                got: cacheVersion
            )
        }

        // Verify dimensions match
        guard decoded.dimensions == provider.dimensions else {
            throw IndexError.dimensionMismatch(
                expected: provider.dimensions,
                got: decoded.dimensions
            )
        }

        // Find changed files
        var changedFiles: Set<String> = []
        for (file, oldHash) in decoded.fileHashes {
            if currentHashes[file] != oldHash {
                changedFiles.insert(file)
            }
        }
        // Also add new files not in cache
        for file in currentHashes.keys {
            if decoded.fileHashes[file] == nil {
                changedFiles.insert(file)
            }
        }

        // Build chunk lookup dictionary O(n) instead of O(n²) linear search
        var chunkById: [String: CodeChunk] = [:]
        for chunk in decoded.chunks {
            chunkById[chunk.id] = chunk
        }

        // Prepare data to load
        var newEmbeddings: [[Float]] = []
        var newChunkIds: [String] = []
        var newChunks: [String: CodeChunk] = [:]

        for (i, chunkId) in decoded.chunkIds.enumerated() {
            if let chunk = chunkById[chunkId] {
                // Skip if file changed
                if changedFiles.contains(chunk.file) { continue }

                newEmbeddings.append(decoded.embeddings[i])
                newChunkIds.append(chunkId)
                newChunks[chunkId] = chunk
            }
        }

        // Update index under write lock
        pthread_rwlock_wrlock(&rwLock)
        embeddings = newEmbeddings
        chunkIds = newChunkIds
        chunks = newChunks
        fileHashes = currentHashes
        pthread_rwlock_unlock(&rwLock)

        // Extract completion status from cache
        let wasComplete = decoded.isComplete ?? false
        let totalExpected = decoded.totalExpectedChunks
        let jobId = decoded.dgxJobId

        if verbose {
            let completeStr = wasComplete ? "complete" : "checkpoint"
            let jobStr = jobId.map { " (job \($0))" } ?? ""
            fputs("[EmbeddingIndex] Loaded \(newEmbeddings.count) cached embeddings (\(completeStr)\(jobStr)), \(changedFiles.count) files changed\n", stderr)
        }

        return LoadResult(
            changedFiles: changedFiles,
            wasComplete: wasComplete,
            totalExpectedChunks: totalExpected,
            dgxJobId: jobId
        )
    }

    /// Get file hashes (for persistence)
    func getFileHashes() -> [String: String] {
        pthread_rwlock_rdlock(&rwLock)
        defer { pthread_rwlock_unlock(&rwLock) }
        return fileHashes
    }

    // MARK: - Cross-Instance Sync

    /// Reload full index from cache file (for syncing from another instance)
    /// Unlike load(), this replaces the entire index without checking for changes
    func reloadFromCache(url: URL) throws {
        // Acquire shared file lock
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: "EmbeddingIndex", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to open cache file for reload"])
        }
        defer { close(fd) }

        guard flock(fd, LOCK_SH) == 0 else {
            throw NSError(domain: "EmbeddingIndex", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to acquire shared lock for reload"])
        }
        defer { flock(fd, LOCK_UN) }

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(IndexData.self, from: data)

        // Verify schema and dimensions
        let cacheVersion = decoded.schemaVersion ?? 0
        guard cacheVersion == kIndexSchemaVersion else {
            throw IndexError.schemaVersionMismatch(expected: kIndexSchemaVersion, got: cacheVersion)
        }
        guard decoded.dimensions == provider.dimensions else {
            throw IndexError.dimensionMismatch(expected: provider.dimensions, got: decoded.dimensions)
        }

        // Build chunk lookup
        var chunkById: [String: CodeChunk] = [:]
        for chunk in decoded.chunks {
            chunkById[chunk.id] = chunk
        }

        // Load all embeddings
        var newEmbeddings: [[Float]] = []
        var newChunkIds: [String] = []
        var newChunks: [String: CodeChunk] = [:]

        for (i, chunkId) in decoded.chunkIds.enumerated() {
            if let chunk = chunkById[chunkId] {
                newEmbeddings.append(decoded.embeddings[i])
                newChunkIds.append(chunkId)
                newChunks[chunkId] = chunk
            }
        }

        // Replace entire index
        pthread_rwlock_wrlock(&rwLock)
        embeddings = newEmbeddings
        chunkIds = newChunkIds
        chunks = newChunks
        fileHashes = decoded.fileHashes
        pthread_rwlock_unlock(&rwLock)

        if verbose {
            fputs("[EmbeddingIndex] Reloaded \(newEmbeddings.count) embeddings from another instance\n", stderr)
        }
    }

    /// Get modification time of a cache file
    static func getCacheModificationTime(url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modTime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modTime
    }

    // MARK: - Math
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        
        return dotProduct / denominator
    }
}

// MARK: - Supporting Types

struct SearchResult: Codable {
    let chunk: CodeChunk
    let score: Float
}

/// Schema version - bump this when chunk extraction logic changes significantly
/// This ensures stale caches are invalidated when the extraction produces different chunks
let kIndexSchemaVersion = 6  // v6: Added dgxJobId for job queue resume

struct IndexData: Codable {
    let schemaVersion: Int?  // nil for old caches (pre-v3)
    let embeddings: [[Float]]
    let chunkIds: [String]
    let chunks: [CodeChunk]
    let providerName: String
    let dimensions: Int
    let fileHashes: [String: String]  // For change detection
    let timestamp: Date
    let isComplete: Bool?  // nil/false = checkpoint, true = full index complete (v5+)
    let totalExpectedChunks: Int?  // Total chunks expected when complete (v5+)
    let dgxJobId: String?  // Active DGX job ID for resume (v6+)
}

enum IndexError: Error, LocalizedError {
    case schemaVersionMismatch(expected: Int, got: Int)
    case dimensionMismatch(expected: Int, got: Int)
    case notIndexed
    
    var errorDescription: String? {
        switch self {
        case .schemaVersionMismatch(let expected, let got):
            return "Schema version mismatch: cache is v\(got), current is v\(expected). Rebuilding index..."
        case .dimensionMismatch(let expected, let got):
            return "Dimension mismatch: expected \(expected), got \(got)"
        case .notIndexed:
            return "Index is empty - call index() first"
        }
    }
}
