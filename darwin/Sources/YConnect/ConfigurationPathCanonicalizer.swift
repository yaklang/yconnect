import Foundation

/// Canonicalizes a configuration path without requiring its leaf to exist.
///
/// Resolving only the deepest existing ancestor catches aliases such as
/// /var versus /private/var and symlinked dotfile directories while still
/// preserving the intended filename for a new target.
enum ConfigurationPathCanonicalizer {
    static func canonicalizedURL(
        _ input: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let standardized = input.standardizedFileURL
        var ancestor = standardized
        var missing: [String] = []
        var isDirectory: ObjCBool = false
        while !fileManager.fileExists(atPath: ancestor.path, isDirectory: &isDirectory),
              ancestor.path != "/" {
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        var result = resolvedAncestor
        for (index, component) in missing.enumerated() {
            result.appendPathComponent(component, isDirectory: index < missing.count - 1)
        }
        return result.standardizedFileURL
    }
}
