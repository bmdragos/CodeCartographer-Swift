import Testing
import SwiftSyntax
import SwiftParser
@testable import CodeCartographer

@Suite("ChunkExtractor Tests")
struct ChunkExtractorTests {

    // MARK: - Chunk Kind Detection

    @Test("Extracts function chunks")
    func extractsFunction() {
        let code = """
        func fetchData() -> Data {
            return Data()
        }
        """
        let chunks = extractChunks(code, filePath: "Utils.swift")

        #expect(chunks.count == 1)
        #expect(chunks.first?.kind == .function)
        #expect(chunks.first?.name == "fetchData")
    }

    @Test("Extracts method chunks from class")
    func extractsMethod() {
        let code = """
        class DataManager {
            func loadData() {
                print("loading")
            }
        }
        """
        let chunks = extractChunks(code, filePath: "DataManager.swift")

        let methodChunks = chunks.filter { $0.kind == .method }
        #expect(methodChunks.count == 1)
        #expect(methodChunks.first?.name == "loadData")
        #expect(methodChunks.first?.parentType == "DataManager")
    }

    @Test("Extracts class chunks")
    func extractsClass() {
        let code = """
        class NetworkService {
            var baseURL: String = ""
        }
        """
        let chunks = extractChunks(code, filePath: "NetworkService.swift")

        let classChunks = chunks.filter { $0.kind == .class }
        #expect(classChunks.count == 1)
        #expect(classChunks.first?.name == "NetworkService")
    }

    @Test("Extracts struct chunks")
    func extractsStruct() {
        let code = """
        struct User {
            let id: Int
            let name: String
        }
        """
        let chunks = extractChunks(code, filePath: "User.swift")

        let structChunks = chunks.filter { $0.kind == .struct }
        #expect(structChunks.count == 1)
        #expect(structChunks.first?.name == "User")
    }

    @Test("Extracts enum chunks")
    func extractsEnum() {
        let code = """
        enum State {
            case loading
            case loaded
            case error
        }
        """
        let chunks = extractChunks(code, filePath: "State.swift")

        let enumChunks = chunks.filter { $0.kind == .enum }
        #expect(enumChunks.count == 1)
        #expect(enumChunks.first?.name == "State")
    }

    @Test("Extracts protocol chunks")
    func extractsProtocol() {
        let code = """
        protocol DataSource {
            func numberOfItems() -> Int
        }
        """
        let chunks = extractChunks(code, filePath: "DataSource.swift")

        let protocolChunks = chunks.filter { $0.kind == .protocol }
        #expect(protocolChunks.count == 1)
        #expect(protocolChunks.first?.name == "DataSource")
    }

    @Test("Extracts initializer chunks")
    func extractsInitializer() {
        let code = """
        class Service {
            init(url: String) {
                print(url)
            }
        }
        """
        let chunks = extractChunks(code, filePath: "Service.swift")

        let initChunks = chunks.filter { $0.kind == .initializer }
        #expect(initChunks.count == 1)
        #expect(initChunks.first?.name == "init")
    }

    // MARK: - Visibility Detection

    @Test("Detects public visibility")
    func detectsPublicVisibility() {
        let code = """
        public func publicFunc() {}
        """
        let chunks = extractChunks(code, filePath: "API.swift")

        #expect(chunks.first?.visibility == .public)
    }

    @Test("Detects private visibility")
    func detectsPrivateVisibility() {
        let code = """
        class Foo {
            private func privateFunc() {}
        }
        """
        let chunks = extractChunks(code, filePath: "Foo.swift")

        let methodChunks = chunks.filter { $0.kind == .method }
        #expect(methodChunks.first?.visibility == .private)
    }

    @Test("Defaults to internal visibility")
    func defaultsToInternalVisibility() {
        let code = """
        func internalFunc() {}
        """
        let chunks = extractChunks(code, filePath: "Internal.swift")

        #expect(chunks.first?.visibility == .internal)
    }

    // MARK: - Layer Inference

    @Test("Infers network layer from path")
    func infersNetworkLayerFromPath() {
        let code = """
        class APIClient {
            func fetch() {}
        }
        """
        // Path must contain "/network/" for pattern matching
        let chunks = extractChunks(code, filePath: "App/Network/APIClient.swift")

        let classChunk = chunks.first { $0.kind == .class }
        #expect(classChunk?.layer == "network")
    }

    @Test("Infers UI layer from path")
    func infersUILayerFromPath() {
        let code = """
        class ProfileView {
            func render() {}
        }
        """
        // Path must contain "/view/" for pattern matching
        let chunks = extractChunks(code, filePath: "App/View/ProfileView.swift")

        let classChunk = chunks.first { $0.kind == .class }
        #expect(classChunk?.layer == "ui")
    }

    @Test("Infers UI layer from type name")
    func infersUILayerFromTypeName() {
        let code = """
        class SettingsViewController {
            func viewDidLoad() {}
        }
        """
        let chunks = extractChunks(code, filePath: "Settings.swift")

        let classChunk = chunks.first { $0.kind == .class }
        #expect(classChunk?.layer == "ui")
    }

    @Test("Infers persistence layer from path")
    func infersPersistenceLayerFromPath() {
        let code = """
        class DataStore {
            func save() {}
        }
        """
        // Path must contain "/storage/" for pattern matching
        let chunks = extractChunks(code, filePath: "App/Storage/DataStore.swift")

        let classChunk = chunks.first { $0.kind == .class }
        #expect(classChunk?.layer == "persistence")
    }

    // MARK: - Pattern Detection

    @Test("Detects async-await pattern")
    func detectsAsyncAwaitPattern() {
        let code = """
        func fetchUser() async throws -> User {
            return await api.getUser()
        }
        """
        let chunks = extractChunks(code, filePath: "UserService.swift")

        #expect(chunks.first?.patterns.contains("async-await") == true)
    }

    @Test("Detects throws pattern")
    func detectsThrowsPattern() {
        let code = """
        func parseJSON() throws -> Data {
            throw NSError()
        }
        """
        let chunks = extractChunks(code, filePath: "Parser.swift")

        #expect(chunks.first?.patterns.contains("throws") == true)
    }

    @Test("Detects callback pattern")
    func detectsCallbackPattern() {
        let code = """
        func loadData(completion: @escaping (Result<Data, Error>) -> Void) {
            completion(.success(Data()))
        }
        """
        let chunks = extractChunks(code, filePath: "Loader.swift")

        #expect(chunks.first?.patterns.contains("callback") == true)
    }

    // MARK: - Attributes and Property Wrappers

    @Test("Extracts MainActor attribute")
    func extractsMainActorAttribute() {
        let code = """
        @MainActor
        class ViewModel {
            func update() {}
        }
        """
        let chunks = extractChunks(code, filePath: "ViewModel.swift")

        let classChunk = chunks.first { $0.kind == .class }
        #expect(classChunk?.attributes.contains("@MainActor") == true)
    }

    @Test("Extracts State property wrapper from struct")
    func extractsStatePropertyWrapper() {
        let code = """
        struct ContentView {
            @State var count: Int = 0
        }
        """
        let chunks = extractChunks(code, filePath: "ContentView.swift")

        // Property wrappers are extracted from the containing type, not individual properties
        let structChunk = chunks.first { $0.kind == .struct }
        #expect(structChunk?.propertyWrappers.contains("@State") == true)
    }

    @Test("Extracts Published property wrapper from class")
    func extractsPublishedPropertyWrapper() {
        let code = """
        class Store {
            @Published var items: [String] = []
        }
        """
        let chunks = extractChunks(code, filePath: "Store.swift")

        // Property wrappers are extracted from the containing type, not individual properties
        let classChunk = chunks.first { $0.kind == .class }
        #expect(classChunk?.propertyWrappers.contains("@Published") == true)
    }

    // MARK: - Relationships

    @Test("Extracts method calls")
    func extractsMethodCalls() {
        let code = """
        class Service {
            func process() {
                fetchData()
                parseResponse()
            }
            func fetchData() {}
            func parseResponse() {}
        }
        """
        let chunks = extractChunks(code, filePath: "Service.swift")

        let processChunk = chunks.first { $0.name == "process" }
        #expect(processChunk?.calls.contains("fetchData") == true)
        #expect(processChunk?.calls.contains("parseResponse") == true)
    }

    @Test("Extracts type references from member accesses")
    func extractsTypeReferences() {
        let code = """
        func process() {
            let result = UserService.shared.fetch()
            NetworkManager.configure()
        }
        """
        let chunks = extractChunks(code, filePath: "Processor.swift")

        let funcChunk = chunks.first { $0.kind == .function }
        // Types are extracted from member accesses (Type.something)
        #expect(funcChunk?.usesTypes.contains("UserService") == true)
        #expect(funcChunk?.usesTypes.contains("NetworkManager") == true)
    }

    @Test("Extracts protocol conformance")
    func extractsProtocolConformance() {
        let code = """
        class MyDelegate: NSObject, UITableViewDelegate, UITableViewDataSource {
        }
        """
        let chunks = extractChunks(code, filePath: "MyDelegate.swift")

        let classChunk = chunks.first { $0.kind == .class }
        #expect(classChunk?.conformsTo.contains("UITableViewDelegate") == true)
        #expect(classChunk?.conformsTo.contains("UITableViewDataSource") == true)
    }

    // MARK: - Signature and Parameters

    @Test("Extracts function signature")
    func extractsFunctionSignature() {
        let code = """
        func calculate(x: Int, y: Int) -> Int {
            return x + y
        }
        """
        let chunks = extractChunks(code, filePath: "Math.swift")

        #expect(chunks.first?.signature.contains("calculate") == true)
        #expect(chunks.first?.parameters.contains("x") == true)
        #expect(chunks.first?.parameters.contains("y") == true)
        #expect(chunks.first?.returnType == "Int")
    }

    // MARK: - Metrics

    @Test("Calculates line count")
    func calculatesLineCount() {
        let code = """
        func multiLine() {
            let a = 1
            let b = 2
            let c = 3
            print(a + b + c)
        }
        """
        let chunks = extractChunks(code, filePath: "Multi.swift")

        #expect(chunks.first?.lineCount == 6)
    }

    // MARK: - Embedding Text

    @Test("Generates embedding text with all components")
    func generatesEmbeddingText() {
        let code = """
        /// Fetches user data from the server
        class UserService {
            func fetchUser(id: Int) async throws -> User {
                return await api.get(id)
            }
        }
        """
        let chunks = extractChunks(code, filePath: "Services/UserService.swift")

        let methodChunk = chunks.first { $0.kind == .method }
        let embeddingText = methodChunk?.embeddingText ?? ""

        #expect(embeddingText.contains("UserService.fetchUser"))
        #expect(embeddingText.contains("Signature:"))
        #expect(embeddingText.contains("Layer:"))
    }

    // MARK: - Module Path

    @Test("Extracts module path from file path")
    func extractsModulePath() {
        let code = """
        func helper() {}
        """
        let chunks = extractChunks(code, filePath: "Features/Auth/Helpers/Utils.swift")

        #expect(chunks.first?.modulePath == "Features/Auth/Helpers")
    }

    // MARK: - Helpers

    private func extractChunks(_ code: String, filePath: String) -> [CodeChunk] {
        let tree = Parser.parse(source: code)
        let imports = extractImports(from: tree)
        let findings = FileFindings()

        let visitor = ChunkVisitor(
            filePath: filePath,
            sourceText: code,
            imports: imports,
            findings: findings
        )
        visitor.walk(tree)

        return visitor.chunks
    }

    private func extractImports(from tree: SourceFileSyntax) -> [String] {
        var imports: [String] = []
        for statement in tree.statements {
            if let importDecl = statement.item.as(ImportDeclSyntax.self) {
                if let moduleName = importDecl.path.first?.name.text {
                    imports.append(moduleName)
                }
            }
        }
        return imports
    }
}
