import Foundation
import NaturalLanguage

// MARK: - Embedding Provider Protocol

/// Protocol for embedding providers - enables swapping between local and remote implementations
protocol EmbeddingProvider {
    /// Embed a single text into a vector
    func embed(_ text: String) throws -> [Float]
    
    /// Batch embed multiple texts (more efficient for some providers)
    func embed(_ texts: [String]) throws -> [[Float]]
    
    /// Dimension of output vectors
    var dimensions: Int { get }
    
    /// Provider name for logging
    var name: String { get }
}

// MARK: - NLEmbedding Provider (Local, Apple)

/// Uses Apple's NLEmbedding for local, on-device embeddings
/// Pros: No setup, fast, private
/// Cons: 512 dimensions, English-focused, may not be ideal for code
final class NLEmbeddingProvider: EmbeddingProvider {
    private let embedding: NLEmbedding
    
    let dimensions: Int
    let name = "NLEmbedding"
    
    init() throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelNotAvailable("NLEmbedding sentence model not available")
        }
        self.embedding = embedding
        self.dimensions = embedding.dimension
    }
    
    func embed(_ text: String) throws -> [Float] {
        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.embeddingFailed("Failed to embed text: \(text.prefix(50))...")
        }
        return vector.map { Float($0) }
    }
    
    func embed(_ texts: [String]) throws -> [[Float]] {
        return try texts.map { try embed($0) }
    }
}

// MARK: - DGX Provider (Local GPU Server)

/// Uses a local DGX/GPU server for embeddings (CodeBERT, BGE, etc.)
/// Configure with endpoint URL
final class DGXEmbeddingProvider: EmbeddingProvider {
    let endpoint: URL
    let modelName: String
    let dimensions: Int
    var name: String { "DGX(\(modelName))" }
    
    private let session: URLSession
    private let timeout: TimeInterval
    
    init(endpoint: URL, modelName: String = "codeBERT", dimensions: Int = 768, timeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.modelName = modelName
        self.dimensions = dimensions
        self.timeout = timeout
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }
    
    func embed(_ text: String) throws -> [Float] {
        return try embed([text])[0]
    }
    
    func embed(_ texts: [String]) throws -> [[Float]] {
        // Build request
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "texts": texts,
            "model": modelName
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        // Synchronous request (for CLI tool)
        var result: [[Float]]?
        var error: Error?
        
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, err in
            defer { semaphore.signal() }
            
            if let err = err {
                error = EmbeddingError.networkError(err.localizedDescription)
                return
            }
            
            guard let data = data else {
                error = EmbeddingError.networkError("No data received")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let embeddings = json["embeddings"] as? [[Double]] {
                    result = embeddings.map { $0.map { Float($0) } }
                } else {
                    error = EmbeddingError.invalidResponse("Unexpected response format")
                }
            } catch let parseError {
                error = EmbeddingError.invalidResponse(parseError.localizedDescription)
            }
        }
        task.resume()
        semaphore.wait()
        
        if let error = error {
            throw error
        }
        
        guard let embeddings = result else {
            throw EmbeddingError.embeddingFailed("No embeddings returned")
        }
        
        return embeddings
    }
}

// MARK: - Errors

enum EmbeddingError: Error, LocalizedError {
    case modelNotAvailable(String)
    case embeddingFailed(String)
    case networkError(String)
    case invalidResponse(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotAvailable(let msg): return "Model not available: \(msg)"
        case .embeddingFailed(let msg): return "Embedding failed: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        }
    }
}
