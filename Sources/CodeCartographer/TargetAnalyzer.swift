import Foundation

// MARK: - Target Analysis

struct TargetInfo: Codable {
    let name: String
    var files: [String]  // file names
    var fileCount: Int { files.count }
}

struct TargetAnalysis: Codable {
    var targets: [TargetInfo]
    var orphanedFiles: [String]  // files in repo but not in any target
    var fileToTargets: [String: [String]]  // file name -> target names
}

class TargetAnalyzer {
    let projectPath: String
    let repoRoot: String
    
    init(projectPath: String, repoRoot: String) {
        self.projectPath = projectPath
        self.repoRoot = repoRoot
    }
    
    func analyze() -> TargetAnalysis? {
        guard let content = try? String(contentsOfFile: projectPath) else {
            fputs("❌ Failed to read project file: \(projectPath)\n", stderr)
            return nil
        }
        
        var targets: [TargetInfo] = []
        
        // Step 1: Find all target names and their Sources build phase UUIDs
        let targetSourcesMap = extractTargetSourcesPhases(from: content)
        
        // Step 2: For each Sources phase, extract the files
        for (targetName, sourcesUUID) in targetSourcesMap {
            let files = extractFilesFromSourcesPhase(uuid: sourcesUUID, in: content)
            if !files.isEmpty {
                targets.append(TargetInfo(name: targetName, files: files))
            }
        }
        
        // Build file -> targets mapping
        var fileToTargets: [String: [String]] = [:]
        for target in targets {
            for file in target.files {
                fileToTargets[file, default: []].append(target.name)
            }
        }
        
        // Find orphaned files (in repo but not in any target)
        let allTargetFiles = Set(targets.flatMap { $0.files })
        let repoFiles = findSwiftFilesInRepo()
        let orphaned = repoFiles.filter { !allTargetFiles.contains($0) }
        
        return TargetAnalysis(
            targets: targets.sorted { $0.files.count > $1.files.count },
            orphanedFiles: orphaned.sorted(),
            fileToTargets: fileToTargets
        )
    }
    
    private func extractTargetSourcesPhases(from content: String) -> [(String, String)] {
        var result: [(String, String)] = []
        
        // Find the PBXNativeTarget section
        guard let startRange = content.range(of: "/* Begin PBXNativeTarget section */"),
              let endRange = content.range(of: "/* End PBXNativeTarget section */") else {
            return result
        }
        
        let section = String(content[startRange.upperBound..<endRange.lowerBound])
        
        // Pattern: UUID /* TargetName */ = { ... buildPhases = ( ... UUID /* Sources */ ... ) ... }
        // We need to find each target block
        
        // Find target names first
        let targetNamePattern = #"([A-F0-9]{24}) \/\* ([^*]+) \*\/ = \{"#
        guard let nameRegex = try? NSRegularExpression(pattern: targetNamePattern) else { return result }
        
        let range = NSRange(section.startIndex..., in: section)
        var targetStarts: [(String, String, Int)] = []  // (uuid, name, position)
        
        nameRegex.enumerateMatches(in: section, range: range) { match, _, _ in
            if let match = match,
               let uuidRange = Range(match.range(at: 1), in: section),
               let nameRange = Range(match.range(at: 2), in: section) {
                let uuid = String(section[uuidRange])
                let name = String(section[nameRange])
                targetStarts.append((uuid, name, match.range.location))
            }
        }
        
        // For each target, find its Sources build phase
        for (_, targetName, startPos) in targetStarts {
            // Find the buildPhases for this target
            let searchStart = section.index(section.startIndex, offsetBy: startPos)
            let searchSection = String(section[searchStart...])
            
            // Look for buildPhases = ( ... ) within this target block
            if let bpRange = searchSection.range(of: "buildPhases = (") {
                let afterBP = searchSection[bpRange.upperBound...]
                if let closeRange = afterBP.range(of: ");") {
                    let buildPhasesContent = String(afterBP[..<closeRange.lowerBound])
                    
                    // Find Sources phase UUID
                    let sourcesPattern = #"([A-F0-9]{24}) \/\* Sources \*\/"#
                    if let sourcesRegex = try? NSRegularExpression(pattern: sourcesPattern),
                       let match = sourcesRegex.firstMatch(in: buildPhasesContent, range: NSRange(buildPhasesContent.startIndex..., in: buildPhasesContent)),
                       let uuidRange = Range(match.range(at: 1), in: buildPhasesContent) {
                        let sourcesUUID = String(buildPhasesContent[uuidRange])
                        result.append((targetName, sourcesUUID))
                    }
                }
            }
        }
        
        return result
    }
    
    private func extractFilesFromSourcesPhase(uuid: String, in content: String) -> [String] {
        var files: [String] = []
        
        // Find the PBXSourcesBuildPhase section
        guard let startRange = content.range(of: "/* Begin PBXSourcesBuildPhase section */"),
              let endRange = content.range(of: "/* End PBXSourcesBuildPhase section */") else {
            return files
        }
        
        let section = String(content[startRange.upperBound..<endRange.lowerBound])
        
        // Find this specific Sources phase by UUID
        let phasePattern = "\(uuid) \\/\\* Sources \\*\\/ = \\{[^}]*files = \\(([^)]+)\\)"
        
        if let regex = try? NSRegularExpression(pattern: phasePattern, options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
           let filesRange = Range(match.range(at: 1), in: section) {
            let filesContent = String(section[filesRange])
            
            // Extract file names: UUID /* FileName.swift in Sources */
            let filePattern = #"\/\* ([^*]+\.swift) in Sources \*\/"#
            if let fileRegex = try? NSRegularExpression(pattern: filePattern) {
                let range = NSRange(filesContent.startIndex..., in: filesContent)
                fileRegex.enumerateMatches(in: filesContent, range: range) { m, _, _ in
                    if let m = m,
                       let nameRange = Range(m.range(at: 1), in: filesContent) {
                        let name = String(filesContent[nameRange]).trimmingCharacters(in: .whitespaces)
                        files.append(name)
                    }
                }
            }
        }
        
        return files
    }
    
    private func findSwiftFilesInRepo() -> [String] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: repoRoot)
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var files: [String] = []
        let excludePatterns = ["Pods", ".build", "DerivedData", "Carthage", "Tests"]
        
        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if excludePatterns.contains(where: { path.contains($0) }) {
                continue
            }
            if fileURL.pathExtension == "swift" {
                files.append(fileURL.lastPathComponent)
            }
        }
        
        return files
    }
}
