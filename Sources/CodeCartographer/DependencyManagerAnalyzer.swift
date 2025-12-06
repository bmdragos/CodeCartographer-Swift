import Foundation

// MARK: - Dependency Manager Analysis (CocoaPods, SPM, Carthage)

struct DependencyManagerReport: Codable {
    let analyzedAt: String
    var hasPodfile: Bool
    var hasPackageSwift: Bool
    var hasCartfile: Bool
    var pods: [PodInfo]
    var swiftPackages: [SwiftPackageInfo]
    var carthageDeps: [CarthageDepInfo]
    var podsByTarget: [String: [String]]
    var totalDependencies: Int
    var recommendations: [String]
}

struct PodInfo: Codable, Hashable {
    let name: String
    let version: String?
    let source: String?  // git URL or spec
    let subspecs: [String]
    var targets: [String]  // All targets using this pod
    let isDevDependency: Bool  // in test target only
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(subspecs)
    }
    
    static func == (lhs: PodInfo, rhs: PodInfo) -> Bool {
        lhs.name == rhs.name && lhs.subspecs == rhs.subspecs
    }
}

struct SwiftPackageInfo: Codable {
    let name: String
    let url: String?
    let version: String?
    let branch: String?
}

struct CarthageDepInfo: Codable {
    let name: String
    let source: String
    let version: String?
}

// MARK: - Dependency Manager Analyzer

class DependencyManagerAnalyzer {
    
    func analyze(projectRoot: URL) -> DependencyManagerReport {
        var pods: [PodInfo] = []
        var packages: [SwiftPackageInfo] = []
        var carthageDeps: [CarthageDepInfo] = []
        var podsByTarget: [String: [String]] = [:]
        var recommendations: [String] = []
        
        let hasPodfile = FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Podfile").path)
        let hasPackageSwift = FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Package.swift").path)
        let hasCartfile = FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Cartfile").path)
        
        // Parse Podfile
        if hasPodfile {
            let podfilePath = projectRoot.appendingPathComponent("Podfile").path
            if let content = try? String(contentsOfFile: podfilePath) {
                let (parsedPods, targetMap) = parsePodfile(content)
                pods = parsedPods
                podsByTarget = targetMap
            }
        }
        
        // Parse Package.swift (basic)
        if hasPackageSwift {
            let packagePath = projectRoot.appendingPathComponent("Package.swift").path
            if let content = try? String(contentsOfFile: packagePath) {
                packages = parsePackageSwift(content)
            }
        }
        
        // Parse Cartfile
        if hasCartfile {
            let cartfilePath = projectRoot.appendingPathComponent("Cartfile").path
            if let content = try? String(contentsOfFile: cartfilePath) {
                carthageDeps = parseCartfile(content)
            }
        }
        
        // Generate recommendations
        if pods.count > 30 {
            recommendations.append("High pod count (\(pods.count)) - consider consolidating or removing unused dependencies")
        }
        
        // Check for common problematic/outdated pods
        let outdatedPods = ["AFNetworking", "SDWebImage", "MBProgressHUD", "SVProgressHUD"]
        let foundOutdated = pods.filter { outdatedPods.contains($0.name) }
        if !foundOutdated.isEmpty {
            recommendations.append("Consider modern alternatives for: \(foundOutdated.map { $0.name }.joined(separator: ", "))")
        }
        
        // Check for AWS pods (relevant to your auth work)
        let awsPods = pods.filter { $0.name.hasPrefix("AWS") }
        if !awsPods.isEmpty {
            recommendations.append("AWS SDK pods found: \(awsPods.map { $0.name }.joined(separator: ", "))")
        }
        
        // Check for RxSwift
        let rxPods = pods.filter { $0.name.contains("Rx") }
        if !rxPods.isEmpty {
            recommendations.append("RxSwift ecosystem: \(rxPods.map { $0.name }.joined(separator: ", "))")
        }
        
        // Check for multiple HTTP clients
        let httpClients = pods.filter { ["Alamofire", "AFNetworking", "Moya"].contains($0.name) }
        if httpClients.count > 1 {
            recommendations.append("Multiple HTTP clients detected - consider standardizing on one")
        }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return DependencyManagerReport(
            analyzedAt: dateFormatter.string(from: Date()),
            hasPodfile: hasPodfile,
            hasPackageSwift: hasPackageSwift,
            hasCartfile: hasCartfile,
            pods: pods.sorted { $0.name < $1.name },
            swiftPackages: packages,
            carthageDeps: carthageDeps,
            podsByTarget: podsByTarget,
            totalDependencies: pods.count + packages.count + carthageDeps.count,
            recommendations: recommendations
        )
    }
    
    // MARK: - Podfile Parser
    
    private func parsePodfile(_ content: String) -> ([PodInfo], [String: [String]]) {
        var podMap: [String: PodInfo] = [:]  // key: "name/subspec" -> deduplicated pod
        var podsByTarget: [String: [String]] = [:]
        var currentTarget: String? = nil
        var isInTestTarget = false
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip comments
            if trimmed.hasPrefix("#") { continue }
            
            // Detect target blocks
            if trimmed.hasPrefix("target") {
                // Extract target name: target 'MyApp' do
                if let match = trimmed.range(of: #"target\s+['\"]([^'\"]+)['\"]"#, options: .regularExpression) {
                    let targetPart = trimmed[match]
                    // Extract just the name
                    if let nameStart = targetPart.firstIndex(of: "'") ?? targetPart.firstIndex(of: "\"") {
                        let afterQuote = targetPart[targetPart.index(after: nameStart)...]
                        if let nameEnd = afterQuote.firstIndex(of: "'") ?? afterQuote.firstIndex(of: "\"") {
                            currentTarget = String(afterQuote[..<nameEnd])
                            isInTestTarget = currentTarget?.contains("Test") ?? false
                        }
                    }
                }
            }
            
            // Detect end of target block
            if trimmed == "end" {
                currentTarget = nil
                isInTestTarget = false
            }
            
            // Detect pod declarations
            if trimmed.hasPrefix("pod ") || trimmed.hasPrefix("pod'") || trimmed.hasPrefix("pod\"") {
                if let podInfo = parsePodLine(trimmed, target: currentTarget, isTest: isInTestTarget) {
                    // Create unique key for deduplication
                    let key = podInfo.subspecs.isEmpty ? podInfo.name : "\(podInfo.name)/\(podInfo.subspecs.joined(separator: "/"))"
                    
                    if var existing = podMap[key] {
                        // Add target to existing pod
                        if let target = currentTarget, !existing.targets.contains(target) {
                            existing.targets.append(target)
                            podMap[key] = existing
                        }
                    } else {
                        podMap[key] = podInfo
                    }
                    
                    if let target = currentTarget {
                        if !podsByTarget[target, default: []].contains(podInfo.name) {
                            podsByTarget[target, default: []].append(podInfo.name)
                        }
                    }
                }
            }
        }
        
        return (Array(podMap.values), podsByTarget)
    }
    
    private func parsePodLine(_ line: String, target: String?, isTest: Bool) -> PodInfo? {
        // pod 'Alamofire', '~> 5.0'
        // pod 'Firebase/Analytics'
        // pod 'AWSCognitoIdentityProvider', '~> 2.27.0'
        
        var name: String = ""
        var version: String? = nil
        var subspecs: [String] = []
        
        // Extract pod name (first quoted string after 'pod')
        let pattern = #"pod\s+['\"]([^'\"]+)['\"]"#
        if let match = line.range(of: pattern, options: .regularExpression) {
            let podPart = line[match]
            if let nameStart = podPart.firstIndex(of: "'") ?? podPart.firstIndex(of: "\"") {
                let afterQuote = podPart[podPart.index(after: nameStart)...]
                if let nameEnd = afterQuote.firstIndex(of: "'") ?? afterQuote.firstIndex(of: "\"") {
                    name = String(afterQuote[..<nameEnd])
                }
            }
        }
        
        if name.isEmpty { return nil }
        
        // Check for subspecs (Firebase/Analytics -> Firebase with subspec Analytics)
        if name.contains("/") {
            let parts = name.split(separator: "/")
            name = String(parts[0])
            subspecs = parts.dropFirst().map { String($0) }
        }
        
        // Extract version (second quoted string, often with ~>)
        let versionPattern = #",\s*['\"]([^'\"]+)['\"]"#
        if let match = line.range(of: versionPattern, options: .regularExpression) {
            let versionPart = line[match]
            if let vStart = versionPart.firstIndex(of: "'") ?? versionPart.firstIndex(of: "\"") {
                let afterQuote = versionPart[versionPart.index(after: vStart)...]
                if let vEnd = afterQuote.firstIndex(of: "'") ?? afterQuote.firstIndex(of: "\"") {
                    version = String(afterQuote[..<vEnd])
                }
            }
        }
        
        return PodInfo(
            name: name,
            version: version,
            source: nil,
            subspecs: subspecs,
            targets: target.map { [$0] } ?? [],
            isDevDependency: isTest
        )
    }
    
    // MARK: - Package.swift Parser (basic)
    
    private func parsePackageSwift(_ content: String) -> [SwiftPackageInfo] {
        var packages: [SwiftPackageInfo] = []
        
        // Look for .package(url: "...", from: "...")
        let pattern = #"\.package\s*\(\s*url:\s*['\"]([^'\"]+)['\"]"#
        
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(content.startIndex..., in: content)
        
        regex?.enumerateMatches(in: content, options: [], range: range) { match, _, _ in
            if let match = match, let urlRange = Range(match.range(at: 1), in: content) {
                let url = String(content[urlRange])
                let name = url.components(separatedBy: "/").last?.replacingOccurrences(of: ".git", with: "") ?? url
                
                packages.append(SwiftPackageInfo(
                    name: name,
                    url: url,
                    version: nil,  // Would need more complex parsing
                    branch: nil
                ))
            }
        }
        
        return packages
    }
    
    // MARK: - Cartfile Parser
    
    private func parseCartfile(_ content: String) -> [CarthageDepInfo] {
        var deps: [CarthageDepInfo] = []
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            // github "owner/repo" "version"
            // git "url" "version"
            let parts = trimmed.components(separatedBy: " ")
            if parts.count >= 2 {
                let source = parts[0]
                let repo = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let version = parts.count > 2 ? parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : nil
                
                let name = repo.components(separatedBy: "/").last ?? repo
                
                deps.append(CarthageDepInfo(
                    name: name,
                    source: repo,
                    version: version
                ))
            }
        }
        
        return deps
    }
}
