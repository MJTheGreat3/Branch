import Foundation

/// The small file left in place of a local file whose content now lives only in OneDrive.
/// It carries enough to restore the file even if Branch's database is lost.
public struct StandIn: Codable, Equatable, Sendable {
    public static let fileExtension = "branch"
    public static let format = "branch-stand-in"

    public var format: String = StandIn.format
    public var version: Int = 1
    public var name: String
    public var size: Int64
    public var modified: Date
    public var quickXorHash: String
    /// Path under the app's OneDrive folder.
    public var remotePath: String
    public var offloadedAt: Date

    public init(name: String, size: Int64, modified: Date, quickXorHash: String, remotePath: String, offloadedAt: Date) {
        self.name = name
        self.size = size
        self.modified = modified
        self.quickXorHash = quickXorHash
        self.remotePath = remotePath
        self.offloadedAt = offloadedAt
    }

    public static func path(for original: String) -> String {
        original + "." + fileExtension
    }

    public static func isStandIn(_ path: String) -> Bool {
        (path as NSString).pathExtension == fileExtension
    }

    /// The original file's path for a stand-in path.
    public static func originalPath(for standIn: String) -> String {
        (standIn as NSString).deletingPathExtension
    }

    public func write(to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func read(from path: String) throws -> StandIn {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(StandIn.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard s.format == format else { throw CocoaError(.fileReadCorruptFile) }
        return s
    }
}
