import Foundation

// MARK: - Call Graph Tracer

/// Traces call relationships through the codebase
final class CallGraphTracer {

    // MARK: - Types

    struct CallNode: Codable {
        let symbol: String          // e.g., "AuthManager.login"
        let file: String?           // source file
        let line: Int?              // line number
        let depth: Int              // distance from root
        let children: [CallNode]    // what this calls (forward) or callers (backward)
    }

    struct CallTrace: Codable {
        let root: String
        let direction: String       // "forward" or "backward"
        let maxDepth: Int
        let nodeCount: Int
        let tree: CallNode
    }

    struct CallPath: Codable {
        let from: String
        let to: String
        let path: [PathNode]
        let length: Int
    }

    struct PathNode: Codable {
        let symbol: String
        let file: String?
        let line: Int?
    }

    struct PathSearchResult: Codable {
        let from: String
        let to: String
        let pathsFound: Int
        let paths: [CallPath]
        let searchedNodes: Int
    }

    // MARK: - Graph Data

    /// Forward edges: symbol -> [symbols it calls]
    private var forwardGraph: [String: Set<String>] = [:]

    /// Backward edges: symbol -> [symbols that call it]
    private var backwardGraph: [String: Set<String>] = [:]

    /// Chunk lookup by symbol
    private var chunksBySymbol: [String: CodeChunk] = [:]

    /// All known symbols
    private var allSymbols: Set<String> = []

    // MARK: - Initialization

    init(chunks: [CodeChunk]) {
        buildGraph(from: chunks)
    }

    private func buildGraph(from chunks: [CodeChunk]) {
        // Index chunks by symbol
        for chunk in chunks {
            let symbol = makeSymbol(chunk)
            chunksBySymbol[symbol] = chunk
            allSymbols.insert(symbol)

            // Also index by just the name for matching
            allSymbols.insert(chunk.name)
            if let parent = chunk.parentType {
                allSymbols.insert("\(parent).\(chunk.name)")
            }
        }

        // Build forward and backward graphs
        for chunk in chunks {
            let caller = makeSymbol(chunk)

            for call in chunk.calls {
                let normalizedCall = normalizeCall(call)

                // Add forward edge
                forwardGraph[caller, default: []].insert(normalizedCall)

                // Add backward edge
                backwardGraph[normalizedCall, default: []].insert(caller)
            }
        }
    }

    private func makeSymbol(_ chunk: CodeChunk) -> String {
        if let parent = chunk.parentType {
            return "\(parent).\(chunk.name)"
        }
        return chunk.name
    }

    /// Normalize a call string to match symbol format
    private func normalizeCall(_ call: String) -> String {
        var s = call
        // Remove trailing () if present
        if s.hasSuffix("()") {
            s = String(s.dropLast(2))
        }
        // Extract just the method name if it's a chain like "foo.bar.baz"
        // Keep "Type.method" but simplify "instance.method" to "method"
        let parts = s.split(separator: ".")
        if parts.count >= 2 {
            let potentialType = String(parts[parts.count - 2])
            let method = String(parts.last!)
            // If the second-to-last looks like a type (starts uppercase), keep it
            if potentialType.first?.isUppercase == true {
                return "\(potentialType).\(method)"
            }
            return method
        }
        return s
    }

    // MARK: - Trace Forward

    /// Trace what a symbol calls, recursively
    func traceForward(from symbol: String, maxDepth: Int = 5) -> CallTrace {
        var visited = Set<String>()
        let tree = buildTree(
            symbol: resolveSymbol(symbol),
            depth: 0,
            maxDepth: maxDepth,
            visited: &visited,
            graph: forwardGraph
        )

        return CallTrace(
            root: symbol,
            direction: "forward",
            maxDepth: maxDepth,
            nodeCount: visited.count,
            tree: tree
        )
    }

    // MARK: - Trace Backward

    /// Trace what calls a symbol, recursively
    func traceBackward(from symbol: String, maxDepth: Int = 5) -> CallTrace {
        var visited = Set<String>()
        let tree = buildTree(
            symbol: resolveSymbol(symbol),
            depth: 0,
            maxDepth: maxDepth,
            visited: &visited,
            graph: backwardGraph
        )

        return CallTrace(
            root: symbol,
            direction: "backward",
            maxDepth: maxDepth,
            nodeCount: visited.count,
            tree: tree
        )
    }

    // MARK: - Find Paths

    /// Find paths between two symbols using BFS
    func findPaths(from source: String, to target: String, maxPaths: Int = 5, maxDepth: Int = 10) -> PathSearchResult {
        let resolvedSource = resolveSymbol(source)
        let resolvedTarget = resolveSymbol(target)

        var paths: [CallPath] = []
        var searchedNodes = 0

        // BFS to find paths
        var queue: [([String], Set<String>)] = [([resolvedSource], Set([resolvedSource]))]

        while !queue.isEmpty && paths.count < maxPaths {
            let (currentPath, visited) = queue.removeFirst()
            searchedNodes += 1

            guard let current = currentPath.last else { continue }
            guard currentPath.count <= maxDepth else { continue }

            // Check if we reached target
            if matchesSymbol(current, target: resolvedTarget) {
                let pathNodes = currentPath.map { sym -> PathNode in
                    let chunk = findChunk(for: sym)
                    return PathNode(symbol: sym, file: chunk?.file, line: chunk?.line)
                }
                paths.append(CallPath(
                    from: source,
                    to: target,
                    path: pathNodes,
                    length: currentPath.count - 1
                ))
                continue
            }

            // Expand neighbors - try both exact match and resolved symbol
            let neighbors = forwardGraph[current] ?? forwardGraph[resolveSymbol(current)] ?? []
            for neighbor in neighbors {
                let resolvedNeighbor = resolveSymbol(neighbor)
                if !visited.contains(neighbor) && !visited.contains(resolvedNeighbor) {
                    var newVisited = visited
                    newVisited.insert(neighbor)
                    newVisited.insert(resolvedNeighbor)
                    queue.append((currentPath + [resolvedNeighbor], newVisited))
                }
            }
        }

        return PathSearchResult(
            from: source,
            to: target,
            pathsFound: paths.count,
            paths: paths,
            searchedNodes: searchedNodes
        )
    }

    // MARK: - Helpers

    private func buildTree(
        symbol: String,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<String>,
        graph: [String: Set<String>]
    ) -> CallNode {
        visited.insert(symbol)

        let chunk = findChunk(for: symbol)

        var children: [CallNode] = []
        if depth < maxDepth {
            // Try both exact match and resolved symbol for graph lookup
            let neighbors = graph[symbol] ?? graph[resolveSymbol(symbol)] ?? []
            for neighbor in neighbors.sorted() {
                let resolvedNeighbor = resolveSymbol(neighbor)
                if !visited.contains(neighbor) && !visited.contains(resolvedNeighbor) {
                    let childNode = buildTree(
                        symbol: resolvedNeighbor,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        visited: &visited,
                        graph: graph
                    )
                    children.append(childNode)
                }
            }
        }

        return CallNode(
            symbol: symbol,
            file: chunk?.file,
            line: chunk?.line,
            depth: depth,
            children: children
        )
    }

    /// Resolve a user-provided symbol to our canonical format
    private func resolveSymbol(_ input: String) -> String {
        let withoutParens = input.replacingOccurrences(of: "()", with: "")

        // First, try to find a fully-qualified match (Type.method)
        // This is preferred over bare method names
        for symbol in allSymbols {
            if symbol.hasSuffix(".\(input)") || symbol.hasSuffix(".\(withoutParens)") {
                return symbol
            }
        }

        // Try exact match (already fully qualified or standalone function)
        if allSymbols.contains(input) && input.contains(".") {
            return input
        }
        if allSymbols.contains(withoutParens) && withoutParens.contains(".") {
            return withoutParens
        }

        // For bare names that exist, return as-is (will be used for graph lookups)
        if allSymbols.contains(input) {
            return input
        }
        if allSymbols.contains(withoutParens) {
            return withoutParens
        }

        // Return as-is and let it be a leaf node
        return input
    }

    /// Check if a symbol matches a target (handles partial matches)
    private func matchesSymbol(_ symbol: String, target: String) -> Bool {
        if symbol == target { return true }
        if symbol.hasSuffix(".\(target)") { return true }
        if target.hasSuffix(".\(symbol)") { return true }

        // Extract just method names and compare
        let symbolMethod = symbol.split(separator: ".").last.map(String.init) ?? symbol
        let targetMethod = target.split(separator: ".").last.map(String.init) ?? target
        return symbolMethod == targetMethod
    }

    /// Find a chunk for a symbol
    private func findChunk(for symbol: String) -> CodeChunk? {
        // Try exact match
        if let chunk = chunksBySymbol[symbol] {
            return chunk
        }

        // Try matching by method name
        let methodName = symbol.split(separator: ".").last.map(String.init) ?? symbol
        for (key, chunk) in chunksBySymbol {
            if key.hasSuffix(".\(methodName)") || chunk.name == methodName {
                return chunk
            }
        }

        return nil
    }

    // MARK: - Statistics

    var stats: (nodes: Int, forwardEdges: Int, backwardEdges: Int) {
        let forwardCount = forwardGraph.values.reduce(0) { $0 + $1.count }
        let backwardCount = backwardGraph.values.reduce(0) { $0 + $1.count }
        return (chunksBySymbol.count, forwardCount, backwardCount)
    }
}
