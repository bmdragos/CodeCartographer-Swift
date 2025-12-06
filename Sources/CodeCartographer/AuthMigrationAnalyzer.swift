import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Auth Migration Analysis

/// Tracks all auth-related property accesses for migration planning
struct AuthMigrationReport: Codable {
    let analyzedAt: String
    var totalAccesses: Int
    var accessesByProperty: [String: Int]
    var accessesByFile: [String: Int]
    var details: [AuthAccess]
    var migrationPriority: [MigrationItem]
}

struct AuthAccess: Codable {
    let file: String
    let line: Int?
    let property: String
    let accessType: AccessType
    let context: String?  // function name
    let fullExpression: String
    
    enum AccessType: String, Codable {
        case read
        case write
        case call
    }
}

struct MigrationItem: Codable {
    let property: String
    let fileCount: Int
    let totalAccesses: Int
    let recommendation: String
}

// MARK: - Auth Property Patterns

struct AuthPatterns {
    // Account.sharedInstance() property accesses
    static let accountProperties: [String: String] = [
        "name": "User's display name",
        "email": "User's email address", 
        "dob": "Date of birth",
        "phone": "Phone number",
        "pwd": "Password (should not be stored!)",
        "accessToken": "Legacy Cognito access token",
        "dataAccessToken": "Backend API access token",
        "cognitoAccessToken": "Cognito access token",
        "cognitoRefreshToken": "Cognito refresh token",
        "cognitoAccessTokenExpiration": "Cognito token expiry",
        "user": "AWSCognitoIdentityUser object",
        "refreshWithUser": "Token refresh method",
        "getToken": "Get token method",
        "logoutUser": "Logout method",
        "loadBackendData": "Load data method",
        "dataLogin": "Backend login method"
    ]
    
    // AccountAuthenticate patterns
    static let authenticateProperties: [String: String] = [
        "pool": "Cognito user pool",
        "signedIn": "Sign-in state flag",
        "loginView": "Login view reference"
    ]
    
    // LoginData patterns  
    static let loginDataProperties: [String: String] = [
        "user": "Cognito user",
        "signedIn": "Sign-in state",
        "checkIfLoggedIn": "Login check method",
        "lastLogin": "Last login date"
    ]
    
    // Direct Cognito SDK usage
    static let cognitoPatterns: [String] = [
        "AWSCognitoIdentityUser",
        "AWSCognitoIdentityUserPool",
        "getSession",
        "getDetails",
        "isSignedIn",
        "signOut"
    ]
}

// MARK: - Auth Analyzer Visitor

final class AuthMigrationVisitor: SyntaxVisitor {
    let filePath: String
    let sourceText: String
    
    private(set) var accesses: [AuthAccess] = []
    private var currentContext: String?
    
    init(filePath: String, sourceText: String) {
        self.filePath = filePath
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }
    
    // Track function context
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        currentContext = node.name.text
        return .visitChildren
    }
    
    override func visitPost(_ node: FunctionDeclSyntax) {
        currentContext = nil
    }
    
    // Detect member access expressions
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let fullExpr = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for Account.sharedInstance().property patterns
        if fullExpr.contains("Account.sharedInstance()") {
            let memberName = node.declName.baseName.text
            if AuthPatterns.accountProperties.keys.contains(memberName) {
                recordAccess(property: "Account.\(memberName)", expression: fullExpr, node: node)
            }
        }
        
        // Check for AccountAuthenticate.sharedInstance().property
        if fullExpr.contains("AccountAuthenticate.sharedInstance()") {
            let memberName = node.declName.baseName.text
            if AuthPatterns.authenticateProperties.keys.contains(memberName) {
                recordAccess(property: "AccountAuthenticate.\(memberName)", expression: fullExpr, node: node)
            }
        }
        
        // Check for LoginData.sharedInstance().property
        if fullExpr.contains("LoginData.sharedInstance()") {
            let memberName = node.declName.baseName.text
            if AuthPatterns.loginDataProperties.keys.contains(memberName) {
                recordAccess(property: "LoginData.\(memberName)", expression: fullExpr, node: node)
            }
        }
        
        // Check for direct Cognito SDK usage
        for pattern in AuthPatterns.cognitoPatterns {
            if fullExpr.contains(pattern) {
                recordAccess(property: "Cognito.\(pattern)", expression: fullExpr, node: node)
                break
            }
        }
        
        // Check for user.isSignedIn, user.getSession, etc.
        if let base = node.base?.description.trimmingCharacters(in: .whitespacesAndNewlines),
           base == "user" || base.hasSuffix(".user") {
            let memberName = node.declName.baseName.text
            if ["isSignedIn", "getSession", "getDetails", "signOut", "delete"].contains(memberName) {
                recordAccess(property: "CognitoUser.\(memberName)", expression: fullExpr, node: node)
            }
        }
        
        return .visitChildren
    }
    
    // Detect assignments (writes)
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // Check if this is an assignment
        let opText = node.operator.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if opText == "=" {
            let leftSide = node.leftOperand.description.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for Account property writes
            if leftSide.contains("Account.sharedInstance()") {
                for prop in AuthPatterns.accountProperties.keys {
                    if leftSide.contains(".\(prop)") {
                        let line = lineNumber(for: node.position)
                        accesses.append(AuthAccess(
                            file: filePath,
                            line: line,
                            property: "Account.\(prop)",
                            accessType: .write,
                            context: currentContext,
                            fullExpression: node.description.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        break
                    }
                }
            }
        }
        
        return .visitChildren
    }
    
    private func recordAccess(property: String, expression: String, node: some SyntaxProtocol) {
        let line = lineNumber(for: node.position)
        
        // Determine if this is a read, write, or call
        let accessType: AuthAccess.AccessType
        if expression.contains("(") && !expression.contains("sharedInstance()") {
            accessType = .call
        } else {
            accessType = .read  // Default to read; writes detected separately
        }
        
        accesses.append(AuthAccess(
            file: filePath,
            line: line,
            property: property,
            accessType: accessType,
            context: currentContext,
            fullExpression: String(expression.prefix(100))  // Truncate long expressions
        ))
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

// MARK: - Report Builder

class AuthMigrationAnalyzer: CachingAnalyzer {
    
    func analyze(parsedFiles: [ParsedFile]) -> AuthMigrationReport {
        var allAccesses: [AuthAccess] = []
        
        for file in parsedFiles {
            let visitor = AuthMigrationVisitor(filePath: file.relativePath, sourceText: file.sourceText)
            visitor.walk(file.ast)
            
            allAccesses.append(contentsOf: visitor.accesses)
        }
        
        // Build summary stats
        var accessesByProperty: [String: Int] = [:]
        var accessesByFile: [String: Int] = [:]
        
        for access in allAccesses {
            accessesByProperty[access.property, default: 0] += 1
            accessesByFile[access.file, default: 0] += 1
        }
        
        // Build migration priority list
        let migrationPriority = buildMigrationPriority(from: accessesByProperty, accesses: allAccesses)
        
        let dateFormatter = ISO8601DateFormatter()
        
        return AuthMigrationReport(
            analyzedAt: dateFormatter.string(from: Date()),
            totalAccesses: allAccesses.count,
            accessesByProperty: accessesByProperty,
            accessesByFile: accessesByFile,
            details: allAccesses,
            migrationPriority: migrationPriority
        )
    }
    
    private func buildMigrationPriority(from byProperty: [String: Int], accesses: [AuthAccess]) -> [MigrationItem] {
        var items: [MigrationItem] = []
        
        for (property, count) in byProperty.sorted(by: { $0.value > $1.value }) {
            let filesWithProperty = Set(accesses.filter { $0.property == property }.map { $0.file })
            
            let recommendation: String
            switch property {
            case "Account.dataAccessToken", "Account.accessToken", "Account.cognitoAccessToken":
                recommendation = "HIGH PRIORITY: Replace with AuthManager.currentValidToken()"
            case "Account.name", "Account.email", "Account.dob", "Account.phone":
                recommendation = "MEDIUM: Read from AuthManager.currentProfile or Keychain"
            case "Account.user", "CognitoUser.isSignedIn", "CognitoUser.getSession":
                recommendation = "HIGH: Remove direct Cognito access, use AuthManager"
            case "Account.refreshWithUser", "Account.getToken":
                recommendation = "HIGH: Replace with AuthManager.validateTokens()"
            case "Account.logoutUser":
                recommendation = "MEDIUM: Replace with AuthManager.logout()"
            case "LoginData.checkIfLoggedIn", "LoginData.signedIn":
                recommendation = "MEDIUM: Replace with AuthManager.isCurrentlyLoggedIn()"
            case let p where p.starts(with: "Cognito."):
                recommendation = "HIGH: Encapsulate in CognitoService, not direct SDK calls"
            default:
                recommendation = "Review and migrate to AuthManager"
            }
            
            items.append(MigrationItem(
                property: property,
                fileCount: filesWithProperty.count,
                totalAccesses: count,
                recommendation: recommendation
            ))
        }
        
        return items
    }
    
    func analyze(files: [URL], relativeTo root: URL) -> AuthMigrationReport {
        let parsedFiles = files.compactMap { try? ParsedFile(url: $0, relativeTo: root) }
        return analyze(parsedFiles: parsedFiles)
    }
}
