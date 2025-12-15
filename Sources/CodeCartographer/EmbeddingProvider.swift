import Foundation
import NaturalLanguage

// MARK: - Embedding Provider Protocol

/// Protocol for embedding providers - enables swapping between local and remote implementations
protocol EmbeddingProvider {
    /// Embed a single text into a vector
    /// - Parameters:
    ///   - text: Text to embed
    ///   - isQuery: If true, this is a search query (DGX adds instruction prefix)
    func embed(_ text: String, isQuery: Bool) throws -> [Float]

    /// Batch embed multiple texts (more efficient for some providers)
    /// - Parameters:
    ///   - texts: Texts to embed
    ///   - isQuery: If true, these are search queries (DGX adds instruction prefix)
    func embed(_ texts: [String], isQuery: Bool) throws -> [[Float]]

    /// Dimension of output vectors
    var dimensions: Int { get }

    /// Provider name for logging
    var name: String { get }
}

// Default implementations for backward compatibility
extension EmbeddingProvider {
    func embed(_ text: String) throws -> [Float] {
        try embed(text, isQuery: false)
    }

    func embed(_ texts: [String]) throws -> [[Float]] {
        try embed(texts, isQuery: false)
    }
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
    
    func embed(_ text: String, isQuery: Bool = false) throws -> [Float] {
        // NLEmbedding doesn't support instruction prefixes, ignore isQuery
        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.embeddingFailed("Failed to embed text: \(text.prefix(50))...")
        }
        return vector.map { Float($0) }
    }

    func embed(_ texts: [String], isQuery: Bool = false) throws -> [[Float]] {
        return try texts.map { try embed($0, isQuery: isQuery) }
    }
}

// MARK: - DGX Provider (Local GPU Server)

/// Uses a local DGX Spark server for embeddings (NV-Embed-v2)
/// Endpoint format: POST /embed with {"inputs": [...]} → [[...]]
final class DGXEmbeddingProvider: EmbeddingProvider {
    let endpoint: URL
    let modelName: String
    let dimensions: Int
    var name: String { "DGX(\(modelName))" }

    private let session: URLSession
    private let timeout: TimeInterval
    private let maxRetries: Int
    private let verbose: Bool

    /// Initialize DGX embedding provider
    /// - Parameters:
    ///   - endpoint: Full URL to the /embed endpoint (e.g., http://192.168.1.159:8080/embed)
    ///   - modelName: Model name for logging (default: NV-Embed-v2)
    ///   - dimensions: Output vector dimensions (default: 4096 for NV-Embed-v2)
    ///   - timeout: Request timeout in seconds (default: 120)
    ///   - maxRetries: Max retry attempts for transient failures (default: 3)
    ///   - verbose: Log retry attempts (default: false)
    init(endpoint: URL, modelName: String = "NV-Embed-v2", dimensions: Int = 4096,
         timeout: TimeInterval = 120, maxRetries: Int = 3, verbose: Bool = false) {
        self.endpoint = endpoint
        self.modelName = modelName
        self.dimensions = dimensions
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.verbose = verbose

        // Configure session for connection reuse and optimal performance
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2  // Total time including retries
        config.httpMaximumConnectionsPerHost = 2  // Allow some parallelism
        config.requestCachePolicy = .reloadIgnoringLocalCacheData  // Don't cache embeddings

        self.session = URLSession(configuration: config)
    }

    func embed(_ text: String, isQuery: Bool = false) throws -> [Float] {
        return try embed([text], isQuery: isQuery)[0]
    }

    func embed(_ texts: [String], isQuery: Bool = false) throws -> [[Float]] {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try performRequest(texts: texts, isQuery: isQuery)
            } catch let error as EmbeddingError {
                lastError = error

                // Only retry on transient failures
                if case .networkError(let msg) = error {
                    let isRetryable = msg.contains("503") ||
                                      msg.contains("timeout") ||
                                      msg.contains("connection") ||
                                      msg.contains("temporarily")

                    if isRetryable && attempt < maxRetries - 1 {
                        // Exponential backoff: 1s, 2s, 4s...
                        let delay = pow(2.0, Double(attempt))
                        if verbose {
                            fputs("[DGX] Retry \(attempt + 1)/\(maxRetries) after \(delay)s: \(msg)\n", stderr)
                        }
                        Thread.sleep(forTimeInterval: delay)
                        continue
                    }
                }
                throw error
            } catch {
                lastError = error
                throw error
            }
        }

        throw lastError ?? EmbeddingError.embeddingFailed("Max retries exceeded")
    }

    private func performRequest(texts: [String], isQuery: Bool = false) throws -> [[Float]] {
        // Build request matching our FastAPI server format
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")  // Accept compressed responses

        // Server expects: {"inputs": [...], "is_query": bool}
        // is_query=true adds instruction prefix for better retrieval
        let payload: [String: Any] = ["inputs": texts, "is_query": isQuery]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Synchronous request (for CLI tool)
        var result: [[Float]]?
        var error: Error?

        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, err in
            defer { semaphore.signal() }

            if let err = err {
                let nsError = err as NSError
                if nsError.code == NSURLErrorTimedOut {
                    error = EmbeddingError.networkError("Request timeout after \(self.timeout)s")
                } else {
                    error = EmbeddingError.networkError(err.localizedDescription)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                error = EmbeddingError.networkError("Invalid response type")
                return
            }

            guard httpResponse.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                error = EmbeddingError.networkError("HTTP \(httpResponse.statusCode): \(body)")
                return
            }

            guard let data = data else {
                error = EmbeddingError.networkError("No data received")
                return
            }

            do {
                // Server returns array directly: [[...]]
                // URLSession automatically decompresses gzip responses
                if let embeddings = try JSONSerialization.jsonObject(with: data) as? [[Double]] {
                    result = embeddings.map { $0.map { Float($0) } }
                } else {
                    error = EmbeddingError.invalidResponse("Expected array of arrays")
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
