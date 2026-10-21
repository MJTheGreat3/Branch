import CryptoKit
import Foundation

/// Glob patterns for files and folders the scanner ignores.
///
/// A pattern without "/" matches any file or folder name (`*.tmp`, `node_modules`).
/// A pattern with "/" matches the path relative to the managed root (`Projects/*/build`).
public struct ExclusionRules: Sendable, Equatable {
    public static let defaultPatterns = [
        ".DS_Store", "._*", ".Trash", ".Spotlight-V100", ".fseventsd",
        "*.tmp", "*.swp", "~$*", ".git", "node_modules", ".build", "DerivedData",
    ]

    public var patterns: [String]

    public init(patterns: [String] = ExclusionRules.defaultPatterns) {
        self.patterns = Self.clean(patterns)
    }

    public func excludes(name: String, relativePath: String? = nil) -> Bool {
        patterns.contains { p in
            if p.contains("/") {
                guard let rel = relativePath else { return false }
                let anchored = p.hasPrefix("/") ? String(p.dropFirst()) : p
                return fnmatch(anchored, rel, FNM_PATHNAME) == 0
            }
            return fnmatch(p, name, 0) == 0
        }
    }

    public func adding(_ more: [String]) -> ExclusionRules {
        ExclusionRules(patterns: patterns + more)
    }

    /// Trims, drops blanks and comments, de-duplicates while keeping order.
    public static func clean(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        return patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }

    /// Parses one pattern per line or comma-separated.
    public static func parse(_ text: String) -> [String] {
        clean(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    }
}

/// A file found on disk during a scan.
public struct ScannedFile: Hashable, Sendable {
    public var relativePath: String
    public var size: Int64
    public var modified: Date
}

/// Result of comparing disk with the last known state.
public struct ScanResult: Sendable {
    /// Files that need uploading, with their content hash.
    public var changed: [(file: ScannedFile, sha256: String)]
    /// Files whose metadata changed but content did not; record should be refreshed without uploading.
    public var touched: [(file: ScannedFile, sha256: String)]
    /// Previously known files no longer on disk. Never propagated to the cloud by default.
    public var missing: [String]
    public var totalFiles: Int
    public var totalBytes: Int64
}

public enum ScanError: Error, Equatable, CustomStringConvertible {
    case folderMissing(String)

    public var description: String {
        switch self {
        case .folderMissing(let p):
            return "Folder not found at \(p). It may have been moved, renamed or deleted, or its drive is disconnected."
        }
    }
}

public enum Scanner {
    /// Lists regular files under `folderPath`, skipping excluded names and `skipping` subtrees.
    /// Returned paths are relative to `rootPath`.
    public static func enumerate(
        folderPath: String,
        rootPath: String,
        skipping: Set<String>,
        rules: ExclusionRules
    ) throws -> [ScannedFile] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            // Never treat an unreachable folder as empty: that would look like every file was deleted.
            throw ScanError.folderMissing(folderPath)
        }
        let url = URL(fileURLWithPath: folderPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folderPath])
        }

        var out: [ScannedFile] = []
        for case let item as URL in walker {
            let path = item.standardizedFileURL.path
            let values = try? item.resourceValues(forKeys: Set(keys))
            let rel = FolderTree.relative(path, to: rootPath)
            if skipping.contains(path) || rules.excludes(name: item.lastPathComponent, relativePath: rel) {
                if values?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            guard values?.isSymbolicLink != true, values?.isRegularFile == true, let rel else { continue }
            out.append(ScannedFile(
                relativePath: rel,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast
            ))
        }
        return out
    }

    /// Compares scanned files with known records. Only hashes files whose size or mtime moved.
    /// `known` should be limited to records within the scanned folder.
    public static func diff(
        scanned: [ScannedFile],
        known: [String: FileRecord],
        rootPath: String
    ) -> ScanResult {
        var changed: [(ScannedFile, String)] = []
        var touched: [(ScannedFile, String)] = []
        var seen = Set<String>()
        var bytes: Int64 = 0

        for file in scanned {
            seen.insert(file.relativePath)
            bytes += file.size
            let prev = known[file.relativePath]
            if let prev, prev.uploadedAt != nil, prev.size == file.size,
               abs(prev.modified.timeIntervalSince(file.modified)) < 0.001 {
                continue
            }
            let abs = (rootPath as NSString).appendingPathComponent(file.relativePath)
            guard let hash = try? sha256(path: abs) else { continue }
            if let prev, prev.uploadedAt != nil, prev.sha256 == hash {
                touched.append((file, hash))
            } else {
                changed.append((file, hash))
            }
        }

        let missing = known.keys.filter { !seen.contains($0) }.sorted()
        return ScanResult(
            changed: changed, touched: touched, missing: missing,
            totalFiles: scanned.count, totalBytes: bytes
        )
    }

    /// Streams a file through SHA-256 so large files don't load into memory.
    public static func sha256(path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
