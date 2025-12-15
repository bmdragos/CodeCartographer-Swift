import Foundation

// MARK: - File Discovery

public func findSwiftFiles(in directory: URL, excluding: [String] = [], includeTests: Bool = false) -> [URL] {
    let fm = FileManager.default

    // Resolve symlinks to get the real path
    let resolvedDirectory = directory.resolvingSymlinksInPath()

    guard let enumerator = fm.enumerator(at: resolvedDirectory, includingPropertiesForKeys: nil) else {
        return []
    }

    var result: [URL] = []
    var excludePatterns = ["Pods", ".build", "DerivedData", "Carthage", "xcodeproj", "xcworkspace"]

    // Only exclude Tests if not explicitly including them
    if !includeTests {
        excludePatterns.append("Tests")
    }

    // Add custom exclusions
    excludePatterns.append(contentsOf: excluding)

    for case let fileURL as URL in enumerator {
        let path = fileURL.path

        // Skip excluded directories
        if excludePatterns.contains(where: { path.contains($0) }) {
            continue
        }

        if fileURL.pathExtension == "swift" {
            result.append(fileURL)
        }
    }
    return result
}

/// Find Swift files including test directories (for test coverage analysis)
public func findAllSwiftFiles(in directory: URL) -> [URL] {
    return findSwiftFiles(in: directory, includeTests: true)
}
