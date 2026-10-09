import Foundation

public struct LibraryLoad: Sendable {
    public var projects: [MatchProject]
    public var unreadableCount: Int
}

public actor ProjectRepository {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func directory(for id: UUID) throws -> URL {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public func save(_ project: MatchProject) throws {
        guard project.schemaVersion == 1, project.courtRegion.isValid else { throw MatchError.incompatibleProject }
        if let editorState = project.editorState,
           abs(editorState.sourceDuration - project.source.duration) > 0.000_001 {
            throw MatchError.incompatibleProject
        }
        try project.editorState?.validate()
        let data = try JSONEncoder().encode(project)
        let url = try directory(for: project.id).appendingPathComponent("project.json")
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    public func load() throws -> LibraryLoad {
        var projects: [MatchProject] = []
        var unreadable = 0
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let metadata = directory.appendingPathComponent("project.json")
            guard FileManager.default.fileExists(atPath: metadata.path) else { continue }
            do {
                var project = try Self.decode(Data(contentsOf: metadata))
                guard project.id.uuidString == directory.lastPathComponent else { throw MatchError.incompatibleProject }
                if project.status == .analyzing { project.status = .interrupted }
                projects.append(project)
            } catch { unreadable += 1 }
        }
        return LibraryLoad(projects: projects.sorted { $0.createdAt > $1.createdAt }, unreadableCount: unreadable)
    }
    public static func decode(_ data: Data) throws -> MatchProject {
        let p = try JSONDecoder().decode(MatchProject.self, from: data)
        guard p.schemaVersion == 1, p.courtRegion.isValid, p.source.duration.isFinite, p.source.duration > 0,
              p.source.filename == URL(fileURLWithPath: p.source.filename).lastPathComponent,
              !p.source.filename.isEmpty else { throw MatchError.incompatibleProject }
        for s in p.segments { try Timeline.validate(start: s.sourceStart, end: s.sourceEnd, duration: p.source.duration) }
        for s in p.pendingAnalysisSegments ?? [] { try Timeline.validate(start: s.sourceStart, end: s.sourceEnd, duration: p.source.duration) }
        if let editorState = p.editorState,
           abs(editorState.sourceDuration - p.source.duration) > 0.000_001 {
            throw MatchError.incompatibleProject
        }
        try p.editorState?.validate()
        return p
    }
    public func delete(_ id: UUID, includingMedia: Bool) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if includingMedia { try FileManager.default.removeItem(at: directory) }
        else { try FileManager.default.removeItem(at: directory.appendingPathComponent("project.json")) }
    }
}
