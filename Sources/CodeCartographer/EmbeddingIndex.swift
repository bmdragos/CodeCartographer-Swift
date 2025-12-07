import Foundation

// MARK: - Embedding Index

/// In-memory index for semantic search over code chunks
final class EmbeddingIndex {
    let provider: EmbeddingProvider
    let cache: ASTCache?
    let verbose: Bool
    
    private var embeddings: [[Float]] = []
    private var chunkIds: [String] = []
    private var chunks: [String: CodeChunk] = [:]  // id -> chunk
    private var fileHashes: [String: String] = [:]  // file -> contentHash (for cache key)
    
    var count: Int { embeddings.count }
    var isEmpty: Bool { embeddings.isEmpty }
    
    init(provider: EmbeddingProvider, cache: ASTCache? = nil, verbose: Bool = false) {
        self.provider = provider
        self.cache = cache
        self.verbose = verbose
    }
    
    /// Set file hashes for embedding cache keys
    func setFileHashes(_ hashes: [String: String]) {
        self.fileHashes = hashes
    }
    
    // MARK: - Indexing
    
    /// Index a batch of chunks with caching support
    func index(_ newChunks: [CodeChunk]) throws {
        guard !newChunks.isEmpty else { return }
        
        var toEmbed: [(index: Int, chunk: CodeChunk)] = []
        var cachedEmbeddings: [(index: Int, embedding: [Float])] = []
        
        // Check cache for each chunk
        for (i, chunk) in newChunks.enumerated() {
            let hash = fileHashes[chunk.file] ?? ""
            if let cached = cache?.getEmbedding(for: chunk.id, contentHash: hash) {
                cachedEmbeddings.append((i, cached))
            } else {
                toEmbed.append((i, chunk))
            }
        }
        
        if verbose && !cachedEmbeddings.isEmpty {
            fputs("[EmbeddingIndex] Embedding cache: \(cachedEmbeddings.count) hits, \(toEmbed.count) to embed\n", stderr)
        }
        
        // Embed only uncached chunks
        var newEmbeddings: [[Float]] = Array(repeating: [], count: newChunks.count)
        
        // Fill in cached
        for (index, embedding) in cachedEmbeddings {
            newEmbeddings[index] = embedding
        }
        
        // Compute new embeddings
        if !toEmbed.isEmpty {
            let texts = toEmbed.map { $0.chunk.embeddingText }
            let computed = try provider.embed(texts)
            
            for (i, (index, chunk)) in toEmbed.enumerated() {
                newEmbeddings[index] = computed[i]
                // Cache the new embedding
                let hash = fileHashes[chunk.file] ?? ""
                cache?.cacheEmbedding(computed[i], for: chunk.id, contentHash: hash)
            }
        }
        
        // Store all
        for (i, chunk) in newChunks.enumerated() {
            embeddings.append(newEmbeddings[i])
            chunkIds.append(chunk.id)
            chunks[chunk.id] = chunk
        }
    }
    
    /// Clear the index
    func clear() {
        embeddings = []
        chunkIds = []
        chunks = [:]
    }
    
    // MARK: - Search
    
    /// Search for chunks similar to the query
    func search(query: String, topK: Int = 10) throws -> [SearchResult] {
        guard !isEmpty else { return [] }
        
        // Embed query
        let queryEmbedding = try provider.embed(query)
        
        // Compute similarities
        var scores: [(index: Int, score: Float)] = []
        for (i, embedding) in embeddings.enumerated() {
            let score = cosineSimilarity(queryEmbedding, embedding)
            scores.append((i, score))
        }
        
        // Sort by score descending
        scores.sort { $0.score > $1.score }
        
        // Return top K
        return scores.prefix(topK).compactMap { item in
            let chunkId = chunkIds[item.index]
            guard let chunk = chunks[chunkId] else { return nil }
            return SearchResult(chunk: chunk, score: item.score)
        }
    }
    
    /// Search with a pre-embedded query vector
    func search(queryVector: [Float], topK: Int = 10) -> [SearchResult] {
        guard !isEmpty else { return [] }
        
        var scores: [(index: Int, score: Float)] = []
        for (i, embedding) in embeddings.enumerated() {
            let score = cosineSimilarity(queryVector, embedding)
            scores.append((i, score))
        }
        
        scores.sort { $0.score > $1.score }
        
        return scores.prefix(topK).compactMap { item in
            let chunkId = chunkIds[item.index]
            guard let chunk = chunks[chunkId] else { return nil }
            return SearchResult(chunk: chunk, score: item.score)
        }
    }
    
    /// Find chunks similar to an existing chunk by its ID
    func similarTo(chunkId: String, topK: Int = 10) -> [SearchResult] {
        guard let index = chunkIds.firstIndex(of: chunkId) else { return [] }
        let embedding = embeddings[index]
        
        // Search excluding self
        return search(queryVector: embedding, topK: topK + 1)
            .filter { $0.chunk.id != chunkId }
            .prefix(topK)
            .map { $0 }
    }
    
    /// Get the embedding vector for a chunk
    func getEmbedding(for chunkId: String) -> [Float]? {
        guard let index = chunkIds.firstIndex(of: chunkId) else { return nil }
        return embeddings[index]
    }
    
    /// Get a chunk by ID
    func getChunk(_ chunkId: String) -> CodeChunk? {
        return chunks[chunkId]
    }
    
    // MARK: - Persistence
    
    /// Save index to disk
    func save(to url: URL) throws {
        let data = IndexData(
            embeddings: embeddings,
            chunkIds: chunkIds,
            chunks: Array(chunks.values),
            providerName: provider.name,
            dimensions: provider.dimensions,
            fileHashes: fileHashes,
            timestamp: Date()
        )
        let encoded = try JSONEncoder().encode(data)
        try encoded.write(to: url)
        
        if verbose {
            let sizeMB = Double(encoded.count) / 1_000_000
            fputs("[EmbeddingIndex] Saved \(embeddings.count) embeddings (\(String(format: "%.1f", sizeMB)) MB) to \(url.lastPathComponent)\n", stderr)
        }
    }
    
    /// Load index from disk, returns set of files that changed (need re-embedding)
    func load(from url: URL, currentHashes: [String: String]) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(IndexData.self, from: data)
        
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
        
        // Load embeddings for unchanged files only
        for (i, chunkId) in decoded.chunkIds.enumerated() {
            if let chunk = decoded.chunks.first(where: { $0.id == chunkId }) {
                // Skip if file changed
                if changedFiles.contains(chunk.file) { continue }
                
                embeddings.append(decoded.embeddings[i])
                chunkIds.append(chunkId)
                chunks[chunkId] = chunk
            }
        }
        
        // Update file hashes
        self.fileHashes = currentHashes
        
        if verbose {
            fputs("[EmbeddingIndex] Loaded \(embeddings.count) cached embeddings, \(changedFiles.count) files changed\n", stderr)
        }
        
        return changedFiles
    }
    
    /// Get file hashes (for persistence)
    func getFileHashes() -> [String: String] {
        return fileHashes
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

struct IndexData: Codable {
    let embeddings: [[Float]]
    let chunkIds: [String]
    let chunks: [CodeChunk]
    let providerName: String
    let dimensions: Int
    let fileHashes: [String: String]  // For change detection
    let timestamp: Date
}

enum IndexError: Error, LocalizedError {
    case dimensionMismatch(expected: Int, got: Int)
    case notIndexed
    
    var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let expected, let got):
            return "Dimension mismatch: expected \(expected), got \(got)"
        case .notIndexed:
            return "Index is empty - call index() first"
        }
    }
}
