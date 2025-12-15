import Foundation

// MARK: - Mermaid Diagram Generator

enum DiagramType: String, CaseIterable {
    case inheritance   // Class hierarchy
    case protocols     // Protocol conformances
    case dependencies  // File/module dependencies
    case full          // Everything combined
    
    var description: String {
        switch self {
        case .inheritance: return "Class inheritance hierarchy"
        case .protocols: return "Protocol conformances"
        case .dependencies: return "File dependencies"
        case .full: return "Full architecture diagram"
        }
    }
}

struct MermaidDiagram: Codable {
    let type: String
    let nodeCount: Int
    let edgeCount: Int
    let mermaid: String
    let renderUrl: String  // Link to Mermaid Live Editor
}

class MermaidGenerator {
    
    // MARK: - Main Entry Point
    
    static func generate(
        typeMap: TypeMap,
        singletonTypes: Set<String> = [],
        diagramType: DiagramType = .full,
        maxNodes: Int = 50
    ) -> MermaidDiagram {
        
        var lines: [String] = ["graph TD"]
        var nodeCount = 0
        var edgeCount = 0
        var addedNodes: Set<String> = []
        
        switch diagramType {
        case .inheritance:
            (nodeCount, edgeCount) = generateInheritance(
                typeMap: typeMap,
                singletonTypes: singletonTypes,
                lines: &lines,
                addedNodes: &addedNodes,
                maxNodes: maxNodes
            )
            
        case .protocols:
            (nodeCount, edgeCount) = generateProtocols(
                typeMap: typeMap,
                lines: &lines,
                addedNodes: &addedNodes,
                maxNodes: maxNodes
            )
            
        case .dependencies:
            (nodeCount, edgeCount) = generateDependencies(
                typeMap: typeMap,
                lines: &lines,
                addedNodes: &addedNodes,
                maxNodes: maxNodes
            )
            
        case .full:
            // Combine all diagrams
            var totalNodes = 0
            var totalEdges = 0
            
            let (n1, e1) = generateInheritance(
                typeMap: typeMap,
                singletonTypes: singletonTypes,
                lines: &lines,
                addedNodes: &addedNodes,
                maxNodes: maxNodes / 2
            )
            totalNodes += n1
            totalEdges += e1
            
            let (n2, e2) = generateProtocols(
                typeMap: typeMap,
                lines: &lines,
                addedNodes: &addedNodes,
                maxNodes: maxNodes / 2
            )
            totalNodes += n2
            totalEdges += e2
            
            nodeCount = addedNodes.count
            edgeCount = totalEdges
        }
        
        let mermaidCode = lines.joined(separator: "\n")
        
        // Mermaid.live expects a JSON state object
        let state = ["code": mermaidCode, "mermaid": "{}", "autoSync": true, "updateDiagram": true] as [String : Any]
        let stateJson = (try? JSONSerialization.data(withJSONObject: state)) ?? Data()
        let encodedState = stateJson.base64EncodedString()
        let renderUrl = "https://mermaid.live/edit#base64:\(encodedState)"
        
        return MermaidDiagram(
            type: diagramType.rawValue,
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            mermaid: mermaidCode,
            renderUrl: renderUrl
        )
    }
    
    // MARK: - Inheritance Diagram
    
    private static func generateInheritance(
        typeMap: TypeMap,
        singletonTypes: Set<String>,
        lines: inout [String],
        addedNodes: inout Set<String>,
        maxNodes: Int
    ) -> (nodes: Int, edges: Int) {
        var nodeCount = 0
        var edgeCount = 0
        
        // Add subgraph for classes
        lines.append("    subgraph Classes")
        
        // Filter to classes with inheritance
        let classesWithInheritance = typeMap.definitions.filter { def in
            def.kind == .class && def.superclass != nil
        }.prefix(maxNodes)
        
        for def in classesWithInheritance {
            let safeName = sanitize(def.name)
            
            // Add node if not already added
            if !addedNodes.contains(safeName) {
                let shape = singletonTypes.contains(def.name) ? "((\(def.name)))" : "[\(def.name)]"
                lines.append("        \(safeName)\(shape)")
                addedNodes.insert(safeName)
                nodeCount += 1
            }
            
            // Add inheritance edge
            if let superclass = def.superclass {
                let safeSuperclass = sanitize(superclass)
                
                // Add superclass node if not exists
                if !addedNodes.contains(safeSuperclass) {
                    lines.append("        \(safeSuperclass)[\(superclass)]")
                    addedNodes.insert(safeSuperclass)
                    nodeCount += 1
                }
                
                // Arrow from subclass to superclass (inherits from)
                lines.append("        \(safeName) -->|extends| \(safeSuperclass)")
                edgeCount += 1
            }
        }
        
        lines.append("    end")
        
        // Style singletons
        for singletonName in singletonTypes {
            let safeName = sanitize(singletonName)
            if addedNodes.contains(safeName) {
                lines.append("    style \(safeName) fill:#f9f,stroke:#333,stroke-width:2px")
            }
        }
        
        return (nodeCount, edgeCount)
    }
    
    // MARK: - Protocol Conformance Diagram
    
    private static func generateProtocols(
        typeMap: TypeMap,
        lines: inout [String],
        addedNodes: inout Set<String>,
        maxNodes: Int
    ) -> (nodes: Int, edges: Int) {
        var nodeCount = 0
        var edgeCount = 0
        
        lines.append("    subgraph Protocols")
        
        // Get protocols with conformers, sorted by popularity
        let sortedProtocols = typeMap.protocolConformances
            .sorted { $0.value.count > $1.value.count }
            .prefix(maxNodes / 3)
        
        for (protocolName, conformers) in sortedProtocols {
            let safeProtocol = sanitize(protocolName)
            
            // Add protocol node (diamond shape)
            if !addedNodes.contains(safeProtocol) {
                lines.append("        \(safeProtocol){{\(protocolName)}}")
                addedNodes.insert(safeProtocol)
                nodeCount += 1
            }
            
            // Add conforming types (limit to top 5 per protocol)
            for conformer in conformers.prefix(5) {
                let safeConformer = sanitize(conformer)
                
                if !addedNodes.contains(safeConformer) {
                    lines.append("        \(safeConformer)[\(conformer)]")
                    addedNodes.insert(safeConformer)
                    nodeCount += 1
                }
                
                // Dotted arrow for conformance
                lines.append("        \(safeConformer) -.->|conforms| \(safeProtocol)")
                edgeCount += 1
            }
        }
        
        lines.append("    end")
        
        // Style protocols differently
        for (protocolName, _) in sortedProtocols {
            let safeProtocol = sanitize(protocolName)
            lines.append("    style \(safeProtocol) fill:#bbf,stroke:#333,stroke-width:2px")
        }
        
        return (nodeCount, edgeCount)
    }
    
    // MARK: - File Dependencies Diagram
    
    private static func generateDependencies(
        typeMap: TypeMap,
        lines: inout [String],
        addedNodes: inout Set<String>,
        maxNodes: Int
    ) -> (nodes: Int, edges: Int) {
        var nodeCount = 0
        var edgeCount = 0
        
        lines.append("    subgraph Files")
        
        // Group by file, showing types per file
        let sortedFiles = typeMap.fileToTypes
            .sorted { $0.value.count > $1.value.count }
            .prefix(maxNodes)
        
        for (file, types) in sortedFiles {
            let fileName = URL(fileURLWithPath: file).lastPathComponent
            let safeFile = sanitize(fileName)
            
            if !addedNodes.contains(safeFile) {
                let typeCount = types.count
                let label = "\(fileName)\\n(\(typeCount) types)"
                lines.append("        \(safeFile)[\"\(label)\"]")
                addedNodes.insert(safeFile)
                nodeCount += 1
            }
        }
        
        lines.append("    end")
        
        // Add cross-file dependencies based on type usage
        // (This would need more analysis - for now, use inheritance)
        for def in typeMap.definitions {
            guard let superclass = def.superclass else { continue }
            let defFile = URL(fileURLWithPath: def.file).lastPathComponent
            if let superclassFile = typeMap.typeToFile[superclass] {
                let superFileName = URL(fileURLWithPath: superclassFile).lastPathComponent
                if defFile != superFileName {
                    let safeFrom = sanitize(defFile)
                    let safeTo = sanitize(superFileName)
                    if addedNodes.contains(safeFrom) && addedNodes.contains(safeTo) {
                        lines.append("    \(safeFrom) --> \(safeTo)")
                        edgeCount += 1
                    }
                }
            }
        }
        
        return (nodeCount, edgeCount)
    }
    
    // MARK: - Helpers
    
    private static func sanitize(_ name: String) -> String {
        // Mermaid-safe identifier: replace special chars
        name.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "<", with: "_")
            .replacingOccurrences(of: ">", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }
}

// MARK: - Diagram for Singletons Only

extension MermaidGenerator {
    
    /// Generate a focused diagram showing only singletons and their dependencies
    static func generateSingletonDiagram(
        singletonRefs: [(name: String, count: Int, files: [String])],
        maxNodes: Int = 30
    ) -> MermaidDiagram {
        var lines: [String] = ["graph LR"]
        var nodeCount = 0
        let edgeCount = 0  // Singletons don't have edges in this view
        
        // Sort by usage count
        let topSingletons = singletonRefs
            .sorted { $0.count > $1.count }
            .prefix(maxNodes)
        
        lines.append("    subgraph Singletons")
        
        // Add singleton nodes (double circle for emphasis)
        for singleton in topSingletons {
            let safeName = sanitize(singleton.name)
            let label = "\(singleton.name)\\n(\(singleton.count) refs)"
            lines.append("        \(safeName)((\"\(label)\"))")
            nodeCount += 1
        }
        
        lines.append("    end")
        
        // Style all singletons
        for singleton in topSingletons {
            let safeName = sanitize(singleton.name)
            lines.append("    style \(safeName) fill:#f9f,stroke:#333,stroke-width:2px")
        }
        
        let mermaidCode = lines.joined(separator: "\n")
        
        // Mermaid.live expects a JSON state object
        let state = ["code": mermaidCode, "mermaid": "{}", "autoSync": true, "updateDiagram": true] as [String : Any]
        let stateJson = (try? JSONSerialization.data(withJSONObject: state)) ?? Data()
        let encodedState = stateJson.base64EncodedString()
        let renderUrl = "https://mermaid.live/edit#base64:\(encodedState)"
        
        return MermaidDiagram(
            type: "singletons",
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            mermaid: mermaidCode,
            renderUrl: renderUrl
        )
    }
}
