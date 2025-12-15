import Testing
import SwiftSyntax
import SwiftParser
@testable import CodeCartographer

@Suite("CallGraphTracer Tests")
struct CallGraphTracerTests {

    // MARK: - Forward Tracing

    @Test("Traces forward calls from a function")
    func tracesForwardCalls() {
        let chunks = makeTestChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        let trace = tracer.traceForward(from: "ServiceA.start", maxDepth: 3)

        #expect(trace.direction == "forward")
        #expect(trace.root == "ServiceA.start")
        #expect(trace.tree.symbol == "ServiceA.start")
        // ServiceA.start calls doWork, which calls helper
        #expect(trace.nodeCount >= 2)
    }

    @Test("Respects max depth in forward trace")
    func respectsMaxDepthForward() {
        let chunks = makeDeepCallChain()
        let tracer = CallGraphTracer(chunks: chunks)

        let trace = tracer.traceForward(from: "level0", maxDepth: 2)

        // Should only go 2 levels deep
        #expect(trace.maxDepth == 2)
        // Count nodes at each level
        var maxDepthFound = 0
        func findMaxDepth(_ node: CallGraphTracer.CallNode) {
            maxDepthFound = max(maxDepthFound, node.depth)
            for child in node.children {
                findMaxDepth(child)
            }
        }
        findMaxDepth(trace.tree)
        #expect(maxDepthFound <= 2)
    }

    // MARK: - Backward Tracing

    @Test("Traces backward callers of a function")
    func tracesBackwardCallers() {
        let chunks = makeTestChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        let trace = tracer.traceBackward(from: "helper", maxDepth: 3)

        #expect(trace.direction == "backward")
        #expect(trace.root == "helper")
        // helper is called by doWork, which is called by start
        #expect(trace.nodeCount >= 1)
    }

    @Test("Handles function with no callers")
    func handlesNoCaller() {
        let chunks = makeTestChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        // entryPoint is not called by anything
        let trace = tracer.traceBackward(from: "ServiceA.start", maxDepth: 3)

        #expect(trace.tree.children.isEmpty || trace.nodeCount == 1)
    }

    // MARK: - Path Finding

    @Test("Finds path between two functions")
    func findsPath() {
        let chunks = makeTestChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        let result = tracer.findPaths(from: "ServiceA.start", to: "helper", maxPaths: 5)

        #expect(result.pathsFound >= 1)
        if let firstPath = result.paths.first {
            #expect(firstPath.from == "ServiceA.start")
            #expect(firstPath.to == "helper")
            #expect(firstPath.length >= 1)
        }
    }

    @Test("Returns empty when no path exists")
    func returnsEmptyWhenNoPath() {
        let chunks = makeDisconnectedChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        let result = tracer.findPaths(from: "isolated1", to: "isolated2", maxPaths: 5)

        #expect(result.pathsFound == 0)
        #expect(result.paths.isEmpty)
    }

    @Test("Respects max paths limit")
    func respectsMaxPathsLimit() {
        let chunks = makeMultiPathChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        let result = tracer.findPaths(from: "start", to: "end", maxPaths: 2)

        #expect(result.pathsFound <= 2)
    }

    // MARK: - Symbol Resolution

    @Test("Resolves partial symbol names")
    func resolvesPartialNames() {
        let chunks = makeTestChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        // Should find "ServiceA.start" when searching for just "start"
        let trace = tracer.traceForward(from: "start", maxDepth: 2)

        #expect(trace.nodeCount >= 1)
    }

    @Test("Handles symbols with parentheses")
    func handlesParentheses() {
        let chunks = makeTestChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        // Should work with or without ()
        let trace1 = tracer.traceForward(from: "ServiceA.start", maxDepth: 2)
        let trace2 = tracer.traceForward(from: "ServiceA.start()", maxDepth: 2)

        #expect(trace1.nodeCount == trace2.nodeCount)
    }

    // MARK: - Edge Cases

    @Test("Handles empty chunk list")
    func handlesEmptyChunks() {
        let tracer = CallGraphTracer(chunks: [])

        let trace = tracer.traceForward(from: "anything", maxDepth: 5)

        #expect(trace.nodeCount == 1) // Just the root node
        #expect(trace.tree.children.isEmpty)
    }

    @Test("Handles circular calls without infinite loop")
    func handlesCircularCalls() {
        let chunks = makeCircularChunks()
        let tracer = CallGraphTracer(chunks: chunks)

        // Should not hang - visited set prevents infinite loop
        let trace = tracer.traceForward(from: "A.call", maxDepth: 10)

        // Should complete and have reasonable count
        #expect(trace.nodeCount <= 3) // A, B, C at most
    }

    // MARK: - Helpers

    private func makeTestChunks() -> [CodeChunk] {
        // ServiceA.start -> ServiceA.doWork -> helper
        return [
            makeChunk(name: "start", parentType: "ServiceA", calls: ["doWork"]),
            makeChunk(name: "doWork", parentType: "ServiceA", calls: ["helper"]),
            makeChunk(name: "helper", parentType: nil, calls: [])
        ]
    }

    private func makeDeepCallChain() -> [CodeChunk] {
        // level0 -> level1 -> level2 -> level3 -> level4
        return [
            makeChunk(name: "level0", parentType: nil, calls: ["level1"]),
            makeChunk(name: "level1", parentType: nil, calls: ["level2"]),
            makeChunk(name: "level2", parentType: nil, calls: ["level3"]),
            makeChunk(name: "level3", parentType: nil, calls: ["level4"]),
            makeChunk(name: "level4", parentType: nil, calls: [])
        ]
    }

    private func makeDisconnectedChunks() -> [CodeChunk] {
        return [
            makeChunk(name: "isolated1", parentType: nil, calls: []),
            makeChunk(name: "isolated2", parentType: nil, calls: [])
        ]
    }

    private func makeMultiPathChunks() -> [CodeChunk] {
        // start -> pathA -> end
        // start -> pathB -> end
        // start -> pathC -> end
        return [
            makeChunk(name: "start", parentType: nil, calls: ["pathA", "pathB", "pathC"]),
            makeChunk(name: "pathA", parentType: nil, calls: ["end"]),
            makeChunk(name: "pathB", parentType: nil, calls: ["end"]),
            makeChunk(name: "pathC", parentType: nil, calls: ["end"]),
            makeChunk(name: "end", parentType: nil, calls: [])
        ]
    }

    private func makeCircularChunks() -> [CodeChunk] {
        // A -> B -> C -> A (circular)
        return [
            makeChunk(name: "call", parentType: "A", calls: ["B.call"]),
            makeChunk(name: "call", parentType: "B", calls: ["C.call"]),
            makeChunk(name: "call", parentType: "C", calls: ["A.call"])
        ]
    }

    private func makeChunk(
        name: String,
        parentType: String?,
        calls: [String]
    ) -> CodeChunk {
        let symbol = parentType != nil ? "\(parentType!).\(name)" : name
        return CodeChunk(
            id: "test:\(symbol)",
            file: "Test.swift",
            line: 1,
            endLine: 10,
            name: name,
            kind: parentType != nil ? .method : .function,
            parentType: parentType,
            modulePath: "Test",
            signature: "func \(name)()",
            parameters: [],
            returnType: nil,
            docComment: nil,
            purpose: nil,
            calls: calls,
            calledBy: [],
            usesTypes: [],
            conformsTo: [],
            complexity: 1,
            lineCount: 10,
            visibility: .internal,
            isSingleton: false,
            hasSmells: false,
            hasTodo: false,
            attributes: [],
            propertyWrappers: [],
            keywords: [],
            layer: "test",
            imports: [],
            patterns: []
        )
    }
}
