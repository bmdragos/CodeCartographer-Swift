import Foundation

// MARK: - Migration Checklist Generator

struct MigrationChecklist: Codable {
    let analyzedAt: String  // Standardized field name
    let generatedAt: String // Alias for compatibility
    let migrationName: String
    var totalTasks: Int
    var estimatedEffort: String
    var phases: [MigrationPhase]
    var markdownOutput: String
}

struct MigrationPhase: Codable {
    let name: String
    let description: String
    var tasks: [MigrationTask]
    var fileCount: Int
    var priority: Priority
    
    enum Priority: String, Codable {
        case critical
        case high
        case medium
        case low
    }
}

struct MigrationTask: Codable {
    let description: String
    var locations: [TaskLocation]
    var completed: Bool
    let recommendation: String
}

struct TaskLocation: Codable {
    let file: String
    let line: Int?
    let currentCode: String?
    let suggestedChange: String?
}

// MARK: - Checklist Generator

class MigrationChecklistGenerator {
    
    /// Generate a migration checklist from auth analysis
    func generateAuthMigrationChecklist(from authReport: AuthMigrationReport) -> MigrationChecklist {
        var phases: [MigrationPhase] = []
        
        // Phase 1: Critical - Token Access
        var tokenTasks: [MigrationTask] = []
        let tokenProperties = authReport.migrationPriority.filter { 
            $0.property.contains("Token") || $0.property.contains("token")
        }
        
        for item in tokenProperties {
            let locations = authReport.details
                .filter { $0.property == item.property }
                .map { TaskLocation(
                    file: $0.file,
                    line: $0.line,
                    currentCode: $0.fullExpression,
                    suggestedChange: suggestReplacement(for: item.property)
                )}
            
            tokenTasks.append(MigrationTask(
                description: "Replace \(item.property) (\(item.totalAccesses) uses in \(item.fileCount) files)",
                locations: locations,
                completed: false,
                recommendation: item.recommendation
            ))
        }
        
        if !tokenTasks.isEmpty {
            phases.append(MigrationPhase(
                name: "Phase 1: Token Access Migration",
                description: "Replace direct token access with AuthManager methods",
                tasks: tokenTasks,
                fileCount: Set(tokenTasks.flatMap { $0.locations.map { $0.file } }).count,
                priority: .critical
            ))
        }
        
        // Phase 2: High - Direct Cognito Usage
        var cognitoTasks: [MigrationTask] = []
        let cognitoProperties = authReport.migrationPriority.filter {
            $0.property.contains("Cognito") || $0.property.contains("getSession") || 
            $0.property.contains("signOut") || $0.property.contains("isSignedIn")
        }
        
        for item in cognitoProperties {
            let locations = authReport.details
                .filter { $0.property == item.property }
                .map { TaskLocation(
                    file: $0.file,
                    line: $0.line,
                    currentCode: $0.fullExpression,
                    suggestedChange: suggestReplacement(for: item.property)
                )}
            
            cognitoTasks.append(MigrationTask(
                description: "Encapsulate \(item.property) (\(item.totalAccesses) uses)",
                locations: locations,
                completed: false,
                recommendation: item.recommendation
            ))
        }
        
        if !cognitoTasks.isEmpty {
            phases.append(MigrationPhase(
                name: "Phase 2: Cognito SDK Encapsulation",
                description: "Remove direct Cognito SDK calls, use CognitoService",
                tasks: cognitoTasks,
                fileCount: Set(cognitoTasks.flatMap { $0.locations.map { $0.file } }).count,
                priority: .high
            ))
        }
        
        // Phase 3: Medium - User Profile
        var profileTasks: [MigrationTask] = []
        let profileKeywords = ["name", "email", "dob", "phone", "pwd"]
        let profileProperties = authReport.migrationPriority.filter { item in
            profileKeywords.contains(where: { item.property.lowercased().contains($0) })
        }
        
        for item in profileProperties {
            let locations = authReport.details
                .filter { $0.property == item.property }
                .map { TaskLocation(
                    file: $0.file,
                    line: $0.line,
                    currentCode: $0.fullExpression,
                    suggestedChange: suggestReplacement(for: item.property)
                )}
            
            profileTasks.append(MigrationTask(
                description: "Migrate \(item.property) to Keychain/AuthManager (\(item.totalAccesses) uses)",
                locations: locations,
                completed: false,
                recommendation: item.recommendation
            ))
        }
        
        if !profileTasks.isEmpty {
            phases.append(MigrationPhase(
                name: "Phase 3: User Profile Migration",
                description: "Read user profile from AuthManager/Keychain instead of Account singleton",
                tasks: profileTasks,
                fileCount: Set(profileTasks.flatMap { $0.locations.map { $0.file } }).count,
                priority: .medium
            ))
        }
        
        // Phase 4: Low - Login State Checks
        var loginStateTasks: [MigrationTask] = []
        let loginStateProperties = authReport.migrationPriority.filter {
            $0.property.contains("checkIfLoggedIn") || $0.property.contains("signedIn") ||
            $0.property.contains("LoginData")
        }
        
        for item in loginStateProperties {
            let locations = authReport.details
                .filter { $0.property == item.property }
                .map { TaskLocation(
                    file: $0.file,
                    line: $0.line,
                    currentCode: $0.fullExpression,
                    suggestedChange: suggestReplacement(for: item.property)
                )}
            
            loginStateTasks.append(MigrationTask(
                description: "Update \(item.property) (\(item.totalAccesses) uses)",
                locations: locations,
                completed: false,
                recommendation: item.recommendation
            ))
        }
        
        if !loginStateTasks.isEmpty {
            phases.append(MigrationPhase(
                name: "Phase 4: Login State Consolidation",
                description: "Consolidate login state checks to AuthManager",
                tasks: loginStateTasks,
                fileCount: Set(loginStateTasks.flatMap { $0.locations.map { $0.file } }).count,
                priority: .low
            ))
        }
        
        // Calculate totals
        let totalTasks = phases.flatMap { $0.tasks }.count
        let totalLocations = phases.flatMap { $0.tasks.flatMap { $0.locations } }.count
        
        let effort: String
        if totalLocations < 20 {
            effort = "Small (~1-2 hours)"
        } else if totalLocations < 50 {
            effort = "Medium (~4-8 hours)"
        } else if totalLocations < 100 {
            effort = "Large (~1-2 days)"
        } else {
            effort = "XL (~3-5 days)"
        }
        
        let markdown = generateMarkdown(phases: phases, totalTasks: totalTasks, effort: effort)
        
        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: Date())
        
        return MigrationChecklist(
            analyzedAt: timestamp,
            generatedAt: timestamp,
            migrationName: "AuthManager Migration",
            totalTasks: totalTasks,
            estimatedEffort: effort,
            phases: phases,
            markdownOutput: markdown
        )
    }
    
    private func suggestReplacement(for property: String) -> String {
        switch property {
        case "Account.dataAccessToken", "Account.accessToken":
            return "AuthManager.shared.currentValidToken()"
        case "Account.cognitoAccessToken":
            return "AuthManager.shared.cachedToken"
        case "Account.name":
            return "KeychainTokenStorage.shared.loadUserProfile()?.name"
        case "Account.email":
            return "KeychainTokenStorage.shared.loadUserProfile()?.email"
        case "Account.dob":
            return "KeychainTokenStorage.shared.loadUserProfile()?.dob"
        case "Account.phone":
            return "KeychainTokenStorage.shared.loadUserProfile()?.phone"
        case "Account.refreshWithUser":
            return "await AuthManager.shared.validateTokens()"
        case "Account.getToken":
            return "await AuthManager.shared.validateTokens()"
        case "Account.logoutUser":
            return "await AuthManager.shared.logout()"
        case "LoginData.checkIfLoggedIn":
            return "AuthManager.shared.isCurrentlyLoggedIn()"
        case "CognitoUser.isSignedIn", "Cognito.isSignedIn":
            return "AuthManager.shared.isCurrentlyLoggedIn()"
        case "CognitoUser.getSession", "Cognito.getSession":
            return "Use CognitoService.refreshSession()"
        case "CognitoUser.signOut", "Cognito.signOut":
            return "await AuthManager.shared.logout()"
        default:
            return "// TODO: Migrate to AuthManager"
        }
    }
    
    private func generateMarkdown(phases: [MigrationPhase], totalTasks: Int, effort: String) -> String {
        var md = """
        # AuthManager Migration Checklist
        
        **Generated:** \(Date())
        **Total Tasks:** \(totalTasks)
        **Estimated Effort:** \(effort)
        
        ---
        
        """
        
        for phase in phases {
            let priorityEmoji: String
            switch phase.priority {
            case .critical: priorityEmoji = "🔴"
            case .high: priorityEmoji = "🟠"
            case .medium: priorityEmoji = "🟡"
            case .low: priorityEmoji = "🟢"
            }
            
            md += """
            
            ## \(priorityEmoji) \(phase.name)
            
            \(phase.description)
            
            **Files affected:** \(phase.fileCount)
            
            """
            
            for task in phase.tasks {
                md += "\n### \(task.description)\n\n"
                md += "**Recommendation:** \(task.recommendation)\n\n"
                md += "| File | Line | Current | Suggested |\n"
                md += "|------|------|---------|----------|\n"
                
                for loc in task.locations.prefix(10) {  // Limit to 10 per task
                    let file = loc.file.components(separatedBy: "/").last ?? loc.file
                    let line = loc.line.map { String($0) } ?? "?"
                    let current = (loc.currentCode ?? "").prefix(30)
                    let suggested = (loc.suggestedChange ?? "").prefix(30)
                    md += "| \(file) | \(line) | `\(current)` | `\(suggested)` |\n"
                }
                
                if task.locations.count > 10 {
                    md += "| ... | ... | +\(task.locations.count - 10) more | ... |\n"
                }
            }
        }
        
        md += """
        
        ---
        
        ## Next Steps
        
        1. Start with Phase 1 (Critical) - token access is the foundation
        2. Run tests after each phase
        3. Keep legacy code working during migration (bridge pattern)
        4. Remove legacy code only after all phases complete
        
        """
        
        return md
    }
}
