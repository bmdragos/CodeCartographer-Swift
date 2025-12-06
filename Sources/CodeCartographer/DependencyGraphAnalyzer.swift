import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Dependency Graph

struct DependencyGraph: Codable {
    let analyzedAt: String
    var nodes: [DependencyNode]
    var edges: [DependencyEdge]
    var metrics: GraphMetrics
}

struct DependencyNode: Codable {
    let file: String
    let imports: [String]
    var inDegree: Int   // how many files import this
    var outDegree: Int  // how many files this imports
    var isHub: Bool     // high connectivity
    var isOrphan: Bool  // no connections
}

struct DependencyEdge: Codable {
    let from: String  // importing file
    let to: String    // imported module/file
    let type: EdgeType
    
    enum EdgeType: String, Codable {
        case moduleImport      // import Foundation
        case internalImport    // references to internal files (inferred)
    }
}

struct GraphMetrics: Codable {
    var totalNodes: Int
    var totalEdges: Int
    var avgInDegree: Double
    var avgOutDegree: Double
    var hubFiles: [String]      // files with high connectivity
    var orphanFiles: [String]   // files with no imports/importers
    var circularDependencies: [[String]]  // cycles detected
}

// MARK: - Type/Class Reference Tracker

struct TypeDefinition: Codable {
    let name: String
    let kind: TypeKind
    let file: String
    let line: Int?
    var conformances: [String]  // protocols
    var superclass: String?
    
    enum TypeKind: String, Codable {
        case `class`
        case `struct`
        case `enum`
        case `protocol`
        case `extension`
    }
}

struct TypeMap: Codable {
    var definitions: [TypeDefinition]
    var typeToFile: [String: String]  // type name -> defining file
    var fileToTypes: [String: [String]]  // file -> types defined
    var protocolConformances: [String: [String]]  // protocol -> conforming types
    var inheritanceChains: [String: [String]]  // class -> superclass chain
}

// MARK: - Type Definition Visitor

final class TypeDefinitionVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var definitions: [TypeDefinition] = []
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let conformances = extractConformances(from: node.inheritanceClause)
        let superclass = extractSuperclass(from: node.inheritanceClause)
        
        definitions.append(TypeDefinition(
            name: name,
            kind: .class,
            file: filePath,
            line: lineNumber(for: node.position),
            conformances: conformances,
            superclass: superclass
        ))
        
        return .visitChildren
    }
    
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let conformances = extractConformances(from: node.inheritanceClause)
        
        definitions.append(TypeDefinition(
            name: name,
            kind: .struct,
            file: filePath,
            line: lineNumber(for: node.position),
            conformances: conformances,
            superclass: nil
        ))
        
        return .visitChildren
    }
    
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let conformances = extractConformances(from: node.inheritanceClause)
        
        definitions.append(TypeDefinition(
            name: name,
            kind: .enum,
            file: filePath,
            line: lineNumber(for: node.position),
            conformances: conformances,
            superclass: nil
        ))
        
        return .visitChildren
    }
    
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let conformances = extractConformances(from: node.inheritanceClause)
        
        definitions.append(TypeDefinition(
            name: name,
            kind: .protocol,
            file: filePath,
            line: lineNumber(for: node.position),
            conformances: conformances,  // protocol inheritance
            superclass: nil
        ))
        
        return .visitChildren
    }
    
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let conformances = extractConformances(from: node.inheritanceClause)
        
        definitions.append(TypeDefinition(
            name: name,
            kind: .extension,
            file: filePath,
            line: lineNumber(for: node.position),
            conformances: conformances,
            superclass: nil
        ))
        
        return .visitChildren
    }
    
    private func extractConformances(from clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause = clause else { return [] }
        return clause.inheritedTypes.map { 
            $0.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    private func extractSuperclass(from clause: InheritanceClauseSyntax?) -> String? {
        guard let clause = clause else { return nil }
        // First item that's not a known protocol is likely the superclass
        let knownProtocols = ["Codable", "Equatable", "Hashable", "Comparable", "Identifiable",
                             "ObservableObject", "View", "Sendable", "Error"]
        
        for inherited in clause.inheritedTypes {
            let name = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !knownProtocols.contains(name) && !name.hasSuffix("Protocol") && !name.hasSuffix("Delegate") {
                return name
            }
        }
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

// MARK: - Dependency Graph Builder

class DependencyGraphAnalyzer {
    
    func analyzeTypes(files: [URL], relativeTo root: URL) -> TypeMap {
        var allDefinitions: [TypeDefinition] = []
        
        for fileURL in files {
            guard let sourceText = try? String(contentsOf: fileURL) else { continue }
            
            let tree = Parser.parse(source: sourceText)
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            
            let visitor = TypeDefinitionVisitor(filePath: relativePath, sourceText: sourceText)
            visitor.walk(tree)
            
            allDefinitions.append(contentsOf: visitor.definitions)
        }
        
        // Build maps
        var typeToFile: [String: String] = [:]
        var fileToTypes: [String: [String]] = [:]
        var protocolConformances: [String: [String]] = [:]
        var inheritanceChains: [String: [String]] = [:]
        
        for def in allDefinitions {
            if def.kind != .extension {
                typeToFile[def.name] = def.file
            }
            fileToTypes[def.file, default: []].append(def.name)
            
            // Track protocol conformances
            for conformance in def.conformances {
                if def.kind != .protocol {  // Don't count protocol inheritance
                    protocolConformances[conformance, default: []].append(def.name)
                }
            }
            
            // Track inheritance
            if let superclass = def.superclass {
                inheritanceChains[def.name] = [superclass]
            }
        }
        
        // Expand inheritance chains
        for (className, _) in inheritanceChains {
            inheritanceChains[className] = buildInheritanceChain(for: className, chains: inheritanceChains)
        }
        
        return TypeMap(
            definitions: allDefinitions,
            typeToFile: typeToFile,
            fileToTypes: fileToTypes,
            protocolConformances: protocolConformances,
            inheritanceChains: inheritanceChains
        )
    }
    
    private func buildInheritanceChain(for className: String, chains: [String: [String]], visited: Set<String> = []) -> [String] {
        guard let directSuper = chains[className]?.first else { return [] }
        if visited.contains(directSuper) { return [directSuper] }  // Cycle detection
        
        var chain = [directSuper]
        chain.append(contentsOf: buildInheritanceChain(for: directSuper, chains: chains, visited: visited.union([className])))
        return chain
    }
    
    func buildDependencyGraph(from fileNodes: [FileNode]) -> DependencyGraph {
        var nodes: [DependencyNode] = []
        var edges: [DependencyEdge] = []
        
        // Build file -> imports map
        var fileImports: [String: Set<String>] = [:]
        for node in fileNodes {
            fileImports[node.path] = Set(node.imports)
        }
        
        // Calculate in-degrees (who imports each module)
        var moduleImporters: [String: Set<String>] = [:]
        for node in fileNodes {
            for imp in node.imports {
                moduleImporters[imp, default: []].insert(node.path)
            }
        }
        
        // Build nodes
        for node in fileNodes {
            let outDegree = node.imports.count
            let inDegree = moduleImporters[node.path]?.count ?? 0
            
            nodes.append(DependencyNode(
                file: node.path,
                imports: node.imports,
                inDegree: inDegree,
                outDegree: outDegree,
                isHub: outDegree > 10 || inDegree > 10,
                isOrphan: outDegree == 0 && inDegree == 0
            ))
            
            // Build edges
            for imp in node.imports {
                edges.append(DependencyEdge(
                    from: node.path,
                    to: imp,
                    type: .moduleImport
                ))
            }
        }
        
        // Calculate metrics
        let totalNodes = nodes.count
        let totalEdges = edges.count
        let avgInDegree = nodes.isEmpty ? 0 : Double(nodes.map { $0.inDegree }.reduce(0, +)) / Double(totalNodes)
        let avgOutDegree = nodes.isEmpty ? 0 : Double(nodes.map { $0.outDegree }.reduce(0, +)) / Double(totalNodes)
        
        let hubFiles = nodes.filter { $0.isHub }.map { $0.file }.sorted()
        let orphanFiles = nodes.filter { $0.isOrphan }.map { $0.file }.sorted()
        
        let dateFormatter = ISO8601DateFormatter()
        
        return DependencyGraph(
            analyzedAt: dateFormatter.string(from: Date()),
            nodes: nodes.sorted { $0.outDegree + $0.inDegree > $1.outDegree + $1.inDegree },
            edges: edges,
            metrics: GraphMetrics(
                totalNodes: totalNodes,
                totalEdges: totalEdges,
                avgInDegree: avgInDegree,
                avgOutDegree: avgOutDegree,
                hubFiles: hubFiles,
                orphanFiles: orphanFiles,
                circularDependencies: []  // TODO: implement cycle detection
            )
        )
    }
}
