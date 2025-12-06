import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Core Data Analysis

struct CoreDataReport: Codable {
    let analyzedAt: String
    var hasCoreData: Bool
    var entities: [CoreDataEntityInfo]
    var fetchRequests: [FetchRequestInfo]
    var contexts: [ManagedObjectContextInfo]
    var patterns: CoreDataPatterns
    var issues: [CoreDataIssue]
    var recommendations: [String]
}

struct CoreDataEntityInfo: Codable {
    let name: String
    let file: String
    let line: Int?
    var properties: [String]
    var relationships: [String]
    var isNSManagedObjectSubclass: Bool
}

struct FetchRequestInfo: Codable {
    let file: String
    let line: Int?
    let entityName: String?
    let hasPredicate: Bool
    let hasSortDescriptor: Bool
    let fetchType: String  // "sync", "async", "batch"
}

struct ManagedObjectContextInfo: Codable {
    let file: String
    let line: Int?
    let contextType: String  // "main", "background", "unknown"
    let usesPerformBlock: Bool
}

struct CoreDataPatterns: Codable {
    var fetchRequestCount: Int
    var batchInsertCount: Int
    var batchDeleteCount: Int
    var batchUpdateCount: Int
    var performBlockCount: Int
    var performAndWaitCount: Int
    var saveCount: Int
    var mainContextUsage: Int
    var backgroundContextUsage: Int
    var nsfetchedResultsControllerCount: Int
}

struct CoreDataIssue: Codable {
    let file: String
    let line: Int?
    let issue: IssueType
    let description: String
    
    enum IssueType: String, Codable {
        case mainThreadFetch = "Main Thread Fetch"
        case missingPredicate = "Missing Predicate"
        case unboundedFetch = "Unbounded Fetch"
        case saveWithoutPerform = "Save Without Perform Block"
        case heavyMigration = "Heavy Migration Risk"
    }
}

// MARK: - Core Data Visitor

final class CoreDataVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var entities: [CoreDataEntityInfo] = []
    private(set) var fetchRequests: [FetchRequestInfo] = []
    private(set) var contexts: [ManagedObjectContextInfo] = []
    private(set) var patterns = CoreDataPatterns(
        fetchRequestCount: 0, batchInsertCount: 0, batchDeleteCount: 0,
        batchUpdateCount: 0, performBlockCount: 0, performAndWaitCount: 0,
        saveCount: 0, mainContextUsage: 0, backgroundContextUsage: 0,
        nsfetchedResultsControllerCount: 0
    )
    private(set) var issues: [CoreDataIssue] = []
    private(set) var hasCoreData = false
    
    private var currentClassName: String?
    private var currentClassProperties: [String] = []
    private var currentClassRelationships: [String] = []
    private var isNSManagedObjectSubclass = false
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Detect Core Data import
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let importName = node.path.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if importName == "CoreData" {
            hasCoreData = true
        }
        return .skipChildren
    }
    
    // Detect NSManagedObject subclasses
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        currentClassName = node.name.text
        currentClassProperties = []
        currentClassRelationships = []
        isNSManagedObjectSubclass = false
        
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                let typeName = inherited.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if typeName == "NSManagedObject" || typeName.contains("ManagedObject") {
                    isNSManagedObjectSubclass = true
                    hasCoreData = true
                }
            }
        }
        
        return .visitChildren
    }
    
    override func visitPost(_ node: ClassDeclSyntax) {
        if isNSManagedObjectSubclass, let name = currentClassName {
            entities.append(CoreDataEntityInfo(
                name: name,
                file: filePath,
                line: lineNumber(for: node.position),
                properties: currentClassProperties,
                relationships: currentClassRelationships,
                isNSManagedObjectSubclass: true
            ))
        }
        currentClassName = nil
        isNSManagedObjectSubclass = false
    }
    
    // Detect @NSManaged properties
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let hasNSManaged = node.attributes.contains { attr in
            attr.description.contains("@NSManaged")
        }
        
        if hasNSManaged {
            hasCoreData = true
            for binding in node.bindings {
                let propName = binding.pattern.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let typeStr = binding.typeAnnotation?.description ?? ""
                
                // Check if it's a relationship (NSSet, Set, or another entity type)
                if typeStr.contains("NSSet") || typeStr.contains("Set<") || typeStr.contains("NSOrderedSet") {
                    currentClassRelationships.append(propName)
                } else {
                    currentClassProperties.append(propName)
                }
            }
        }
        
        return .visitChildren
    }
    
    // Detect Core Data function calls
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullCall = node.description
        
        // Fetch requests
        if callText.contains("NSFetchRequest") || callText.contains("FetchRequest") {
            patterns.fetchRequestCount += 1
            hasCoreData = true
            
            let hasPredicate = fullCall.contains("predicate")
            let hasSort = fullCall.contains("sortDescriptor")
            
            fetchRequests.append(FetchRequestInfo(
                file: filePath,
                line: lineNumber(for: node.position),
                entityName: extractEntityName(from: fullCall),
                hasPredicate: hasPredicate,
                hasSortDescriptor: hasSort,
                fetchType: "sync"
            ))
            
            if !hasPredicate {
                issues.append(CoreDataIssue(
                    file: filePath,
                    line: lineNumber(for: node.position),
                    issue: .missingPredicate,
                    description: "Fetch request without predicate may return all objects"
                ))
            }
        }
        
        // Batch operations
        if callText.contains("NSBatchInsertRequest") {
            patterns.batchInsertCount += 1
            hasCoreData = true
        }
        if callText.contains("NSBatchDeleteRequest") {
            patterns.batchDeleteCount += 1
            hasCoreData = true
        }
        if callText.contains("NSBatchUpdateRequest") {
            patterns.batchUpdateCount += 1
            hasCoreData = true
        }
        
        // Context operations
        if callText.contains("performBlock") || callText.contains("perform {") {
            patterns.performBlockCount += 1
        }
        if callText.contains("performAndWait") {
            patterns.performAndWaitCount += 1
        }
        if callText.contains(".save()") || callText.contains("save()") {
            patterns.saveCount += 1
        }
        
        // Context types
        if callText.contains("viewContext") || callText.contains("mainContext") {
            patterns.mainContextUsage += 1
        }
        if callText.contains("newBackgroundContext") || callText.contains("backgroundContext") {
            patterns.backgroundContextUsage += 1
        }
        
        // NSFetchedResultsController
        if callText.contains("NSFetchedResultsController") {
            patterns.nsfetchedResultsControllerCount += 1
            hasCoreData = true
        }
        
        return .visitChildren
    }
    
    // Detect member access patterns
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let memberName = node.declName.baseName.text
        let fullExpr = node.description
        
        if memberName == "viewContext" {
            patterns.mainContextUsage += 1
            hasCoreData = true
        }
        if memberName == "newBackgroundContext" {
            patterns.backgroundContextUsage += 1
            hasCoreData = true
        }
        
        return .visitChildren
    }
    
    private func extractEntityName(from text: String) -> String? {
        // Try to extract entity name from NSFetchRequest<EntityName> or fetchRequest(for: Entity.self)
        if let range = text.range(of: #"NSFetchRequest<(\w+)>"#, options: .regularExpression) {
            let match = text[range]
            if let start = match.firstIndex(of: "<"), let end = match.firstIndex(of: ">") {
                return String(match[match.index(after: start)..<end])
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

// MARK: - Core Data Analyzer

class CoreDataAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> CoreDataReport {
        var allEntities: [CoreDataEntityInfo] = []
        var allFetchRequests: [FetchRequestInfo] = []
        var allContexts: [ManagedObjectContextInfo] = []
        var totalPatterns = CoreDataPatterns(
            fetchRequestCount: 0, batchInsertCount: 0, batchDeleteCount: 0,
            batchUpdateCount: 0, performBlockCount: 0, performAndWaitCount: 0,
            saveCount: 0, mainContextUsage: 0, backgroundContextUsage: 0,
            nsfetchedResultsControllerCount: 0
        )
        var allIssues: [CoreDataIssue] = []
        var hasCoreData = false
        
        for file in parsedFiles {
            let visitor = CoreDataVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            if visitor.hasCoreData {
                hasCoreData = true
            }
            
            allEntities.append(contentsOf: visitor.entities)
            allFetchRequests.append(contentsOf: visitor.fetchRequests)
            allContexts.append(contentsOf: visitor.contexts)
            allIssues.append(contentsOf: visitor.issues)
            
            // Aggregate patterns
            totalPatterns.fetchRequestCount += visitor.patterns.fetchRequestCount
            totalPatterns.batchInsertCount += visitor.patterns.batchInsertCount
            totalPatterns.batchDeleteCount += visitor.patterns.batchDeleteCount
            totalPatterns.batchUpdateCount += visitor.patterns.batchUpdateCount
            totalPatterns.performBlockCount += visitor.patterns.performBlockCount
            totalPatterns.performAndWaitCount += visitor.patterns.performAndWaitCount
            totalPatterns.saveCount += visitor.patterns.saveCount
            totalPatterns.mainContextUsage += visitor.patterns.mainContextUsage
            totalPatterns.backgroundContextUsage += visitor.patterns.backgroundContextUsage
            totalPatterns.nsfetchedResultsControllerCount += visitor.patterns.nsfetchedResultsControllerCount
        }
        
        // Generate recommendations
        var recommendations: [String] = []
        
        if totalPatterns.mainContextUsage > totalPatterns.backgroundContextUsage * 2 {
            recommendations.append("Heavy main context usage - consider moving fetches to background contexts")
        }
        if totalPatterns.performBlockCount == 0 && totalPatterns.saveCount > 0 {
            recommendations.append("Saves without perform blocks detected - ensure thread safety")
        }
        if totalPatterns.batchInsertCount == 0 && allEntities.count > 10 {
            recommendations.append("Consider using batch inserts for better performance")
        }
        if allIssues.filter({ $0.issue == .missingPredicate }).count > 5 {
            recommendations.append("Many fetch requests without predicates - may cause performance issues")
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return CoreDataReport(
            analyzedAt: dateFormatter.string(from: Date()),
            hasCoreData: hasCoreData,
            entities: allEntities,
            fetchRequests: allFetchRequests,
            contexts: allContexts,
            patterns: totalPatterns,
            issues: allIssues,
            recommendations: recommendations
        )
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> CoreDataReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
