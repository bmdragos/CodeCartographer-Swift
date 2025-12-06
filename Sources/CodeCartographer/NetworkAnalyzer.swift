import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Network Call Analysis

struct NetworkCallReport: Codable {
    let analyzedAt: String
    var totalEndpoints: Int
    var totalNetworkFiles: Int
    var endpoints: [EndpointUsage]
    var networkPatterns: [NetworkPattern]
    var filesByNetworkUsage: [String: Int]
}

struct EndpointUsage: Codable {
    let endpoint: String      // e.g., "/user/login", "/api/v1/tests"
    let method: String?       // GET, POST, PUT, DELETE
    let file: String
    let line: Int?
    let context: String?      // function name
}

struct NetworkPattern: Codable {
    let pattern: String
    let count: Int
    let files: [String]
    let description: String
}

// MARK: - Network Visitor

final class NetworkVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var endpoints: [EndpointUsage] = []
    private(set) var networkPatterns: Set<String> = []
    private var currentContext: String?
    
    // Common network patterns to detect
    private let urlPatterns = [
        "/api/", "/v1/", "/v2/", "/user/", "/auth/", "/login", "/logout",
        "/tests", "/appointments", "/locations", "/physicians"
    ]
    
    private let networkKeywords = [
        "URLSession", "URLRequest", "Alamofire", "AF.", "Moya",
        "dataTask", "downloadTask", "uploadTask",
        "RxAlamofire", "rx.request", "rx.data",
        "httpMethod", "HTTPMethod"
    ]
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }
    
    // Detect string literals that look like endpoints
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let content = node.description.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        
        // Check if it looks like an API endpoint
        for pattern in urlPatterns {
            if content.contains(pattern) {
                let method = detectHTTPMethod(near: node)
                endpoints.append(EndpointUsage(
                    endpoint: content,
                    method: method,
                    file: filePath,
                    line: lineNumber(for: node.position),
                    context: currentContext
                ))
                break
            }
        }
        
        return .skipChildren
    }
    
    // Detect network-related function calls
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let fullExpr = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        for keyword in networkKeywords {
            if fullExpr.contains(keyword) {
                networkPatterns.insert(keyword)
                break
            }
        }
        
        return .visitChildren
    }
    
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        
        // Skip short names (false positives like 'data', 'i', 'x')
        guard name.count > 5 else { return .visitChildren }
        
        for keyword in networkKeywords {
            if name.contains(keyword) {
                networkPatterns.insert(name)
                break
            }
        }
        
        return .visitChildren
    }
    
    private func detectHTTPMethod(near node: some SyntaxProtocol) -> String? {
        // Look in surrounding context for HTTP method hints
        let context = node.parent?.description ?? ""
        
        if context.contains("GET") || context.contains(".get") { return "GET" }
        if context.contains("POST") || context.contains(".post") { return "POST" }
        if context.contains("PUT") || context.contains(".put") { return "PUT" }
        if context.contains("DELETE") || context.contains(".delete") { return "DELETE" }
        if context.contains("PATCH") || context.contains(".patch") { return "PATCH" }
        
        return nil
    }
    
    private func lineNumber(for position: AbsolutePosition) -> Int? {
        let offset = position.utf8Offset
        var line = 1
        var currentOffset = 0
        
        for char in sourceText.utf8 {
            if currentOffset >= offset { break }
            if char == UInt8(ascii: "\n") { line += 1 }
            currentOffset += 1
        }
        
        return line
    }
}

// MARK: - Network Analyzer

class NetworkAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> NetworkCallReport {
        var allEndpoints: [EndpointUsage] = []
        var patternCounts: [String: (Int, Set<String>)] = [:]  // pattern -> (count, files)
        var fileNetworkUsage: [String: Int] = [:]
        
        for file in parsedFiles {
            let visitor = NetworkVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            allEndpoints.append(contentsOf: visitor.endpoints)
            
            if !visitor.endpoints.isEmpty || !visitor.networkPatterns.isEmpty {
                fileNetworkUsage[file.relativePath] = visitor.endpoints.count + visitor.networkPatterns.count
            }
            
            for pattern in visitor.networkPatterns {
                var (count, fileSet) = patternCounts[pattern] ?? (0, Set<String>())
                count += 1
                fileSet.insert(file.relativePath)
                patternCounts[pattern] = (count, fileSet)
            }
        }
        
        // Build network patterns summary
        let patterns = patternCounts.map { (pattern, data) in
            NetworkPattern(
                pattern: pattern,
                count: data.0,
                files: Array(data.1).sorted(),
                description: describePattern(pattern)
            )
        }.sorted { $0.count > $1.count }
        
        // Deduplicate endpoints
        var uniqueEndpoints: [String: EndpointUsage] = [:]
        for endpoint in allEndpoints {
            let key = "\(endpoint.endpoint)|\(endpoint.file)"
            if uniqueEndpoints[key] == nil {
                uniqueEndpoints[key] = endpoint
            }
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return NetworkCallReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalEndpoints: uniqueEndpoints.count,
            totalNetworkFiles: fileNetworkUsage.count,
            endpoints: Array(uniqueEndpoints.values).sorted { $0.endpoint < $1.endpoint },
            networkPatterns: patterns,
            filesByNetworkUsage: fileNetworkUsage
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> NetworkCallReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
    
    private func describePattern(_ pattern: String) -> String {
        switch pattern {
        case "URLSession": return "Apple's native networking"
        case "URLRequest": return "URL request construction"
        case "Alamofire", "AF.": return "Alamofire HTTP client"
        case "Moya": return "Moya network abstraction"
        case "RxAlamofire": return "Reactive Alamofire"
        case "dataTask": return "URLSession data task"
        case "rx.request", "rx.data": return "RxSwift network extension"
        default: return "Network-related code"
        }
    }
}
