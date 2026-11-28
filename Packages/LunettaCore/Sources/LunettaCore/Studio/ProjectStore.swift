import Foundation

public struct ProjectStore: Sendable {
    private static let projectFileName = "project.json"

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    public func create(_ project: RecordingProject) throws -> URL {
        let folder = folder(for: project.id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("cursors", isDirectory: true), withIntermediateDirectories: true)
        try save(project)
        return folder
    }

    public func save(_ project: RecordingProject) throws {
        try project.encoded().write(to: projectFile(for: project.id), options: .atomic)
    }

    public func load(_ id: UUID) throws(ProjectError) -> RecordingProject {
        let file = projectFile(for: id)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw .unreadable(file: file.path, reason: error.localizedDescription)
        }
        return try RecordingProject.decode(data, file: file.path)
    }

    public func pendingRenders() -> [RecordingProject] {
        allProjects()
            .filter { $0.renderedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func reservedOutputFiles() -> Set<URL> {
        Set(pendingRenders().map { $0.output.file.standardizedFileURL })
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }

    /// Also takes folders that never got a project, left by a recording that crashed or failed to save.
    public func sweep(olderThan cutoff: Date) -> [UUID] {
        folderIDs()
            .filter { id in
                if let project = try? load(id) { return project.renderedAt.map { $0 < cutoff } ?? false }
                return !FileManager.default.fileExists(atPath: projectFile(for: id).path) && modified(folder(for: id), before: cutoff)
            }
            .filter { (try? delete($0)) != nil }
    }

    private func projectFile(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(Self.projectFileName)
    }

    private func modified(_ folder: URL, before cutoff: Date) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path)
        return (attributes?[.modificationDate] as? Date).map { $0 < cutoff } ?? false
    }

    private func folderIDs() -> [UUID] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    private func allProjects() -> [RecordingProject] {
        folderIDs().compactMap { try? load($0) }
    }
}
