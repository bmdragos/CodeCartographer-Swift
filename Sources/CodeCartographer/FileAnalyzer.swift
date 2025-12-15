import Foundation
import SwiftSyntax
import SwiftParser

public final class FileAnalyzer: SyntaxVisitor {
    public let filePath: String
    public let sourceText: String

    public private(set) var imports: Set<String> = []
    public private(set) var references: [SymbolReference] = []

    // Track current context (function/method we're inside)
    private var currentContext: String?

    public init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Import Detection

    public override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let moduleName = node.path.first?.name.text {
            imports.insert(moduleName)
        }
        return .skipChildren
    }

    // MARK: - Context Tracking

    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        return .visitChildren
    }

    public override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }

    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = "init"
        return .visitChildren
    }

    public override func visitPost(_ node: InitializerDeclSyntax) {
        currentContext = nil
    }

    // MARK: - Member Access Detection (Foo.bar)

    public override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let baseText = node.base?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nameText = node.declName.baseName.text
        let full = baseText.isEmpty ? nameText : "\(baseText).\(nameText)"
        
        if let kind = detectKind(fullSymbol: full) {
            let line = lineNumber(for: node.position)
            references.append(SymbolReference(
                kind: kind,
                symbol: full,
                line: line,
                context: currentContext
            ))
        }

        return .visitChildren
    }

    // MARK: - Function Call Detection

    public override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Handle chained calls like Account.sharedInstance().refreshWithUser(...)
        let callText = node.calledExpression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let kind = detectKind(fullSymbol: callText) {
            let line = lineNumber(for: node.position)
            references.append(SymbolReference(
                kind: kind,
                symbol: callText,
                line: line,
                context: currentContext
            ))
        }
        
        return .visitChildren
    }

    // MARK: - Pattern Detection
    
    private func detectKind(fullSymbol: String) -> SymbolReference.Kind? {
        // Global singletons - the main targets
        let singletonPatterns = [
            "Account.sharedInstance",
            "LoginData.sharedInstance",
            "AccountAuthenticate.sharedInstance",
            "Network.sharedInstance",
            "LongevityScore.sharedInstance",
            "SplashScreen.sharedInstance",
            "TimeLogging.sharedInstance"
        ]
        
        for pattern in singletonPatterns {
            if fullSymbol.contains(pattern) {
                return .globalSingleton
            }
        }
        
        // Account property access (what we need for AuthManager migration)
        let accountProperties = [
            "Account.sharedInstance().name",
            "Account.sharedInstance().email",
            "Account.sharedInstance().dob",
            "Account.sharedInstance().phone",
            "Account.sharedInstance().dataAccessToken",
            "Account.sharedInstance().accessToken",
            "Account.sharedInstance().cognitoAccessToken",
            "Account.sharedInstance().user",
            "Account.sharedInstance().refreshWithUser",
            "Account.sharedInstance().loadBackendData",
            "Account.sharedInstance().logoutUser"
        ]
        
        for prop in accountProperties {
            if fullSymbol.contains(prop) {
                return .propertyAccess
            }
        }
        
        // UserDefaults
        if fullSymbol.contains("UserDefaults.standard") || fullSymbol.contains("UserDefaults()") {
            return .userDefaults
        }
        
        // NotificationCenter
        if fullSymbol.contains("NotificationCenter.default") {
            return .notificationCenter
        }
        
        // AWS Cognito
        if fullSymbol.contains("AWSCognitoIdentityUser") ||
           fullSymbol.contains("AWSCognitoIdentityUserPool") ||
           fullSymbol.contains("pool?.currentUser") ||
           fullSymbol.contains("pool?.getUser") {
            return .awsCognito
        }
        
        // Keychain
        if fullSymbol.contains("Keychain") || fullSymbol.contains("keychain") {
            return .keychain
        }
        
        return nil
    }
    
    // MARK: - Line Number Calculation
    
    private func lineNumber(for position: AbsolutePosition) -> Int? {
        let offset = position.utf8Offset
        var line = 1
        var currentOffset = 0
        
        for char in sourceText.utf8 {
            if currentOffset >= offset {
                break
            }
            if char == UInt8(ascii: "\n") {
                line += 1
            }
            currentOffset += 1
        }
        
        return line
    }
}
