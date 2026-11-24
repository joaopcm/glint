import Foundation
import Observation

public struct UploadRecord: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public let link: URL
    public let date: Date

    public var id: String { key }

    public init(key: String, link: URL, date: Date) {
        self.key = key
        self.link = link
        self.date = date
    }
}

@MainActor @Observable
public final class UploadHistory {
    public private(set) var records: [UploadRecord] = []
    public private(set) var deleting: Set<String> = []
    public private(set) var error: String?
    private let file: URL
    private let fileIsReadable: Bool

    public init(file: URL) {
        self.file = file
        do {
            let data = try Data(contentsOf: file)
            records = try JSONDecoder().decode([UploadRecord].self, from: data).sorted { $0.date > $1.date }
            fileIsReadable = true
        } catch CocoaError.fileReadNoSuchFile {
            fileIsReadable = true
        } catch {
            fileIsReadable = false
            self.error = "Couldn't read the upload history at \(file.path): \(error.localizedDescription). "
                + "Glint leaves that file as it is, so new uploads are listed only until Glint quits."
        }
    }

    public func add(_ uploaded: UploadedCapture, at date: Date = Date()) {
        records.append(UploadRecord(key: uploaded.key, link: uploaded.link, date: date))
        records.sort { $0.date > $1.date }
        save()
    }

    public func delete(_ record: UploadRecord, deleteObject: (String) async throws -> Void) async {
        deleting.insert(record.key)
        defer { deleting.remove(record.key) }
        do {
            try await deleteObject(record.key)
        } catch {
            self.error = "Couldn't delete \(record.key): \(error.localizedDescription)"
            return
        }
        records.removeAll { $0.key == record.key }
        error = nil
        save()
    }

    private func save() {
        guard fileIsReadable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
        } catch {
            self.error = "Couldn't save the upload history to \(file.path): \(error.localizedDescription)"
        }
    }
}

extension BucketAccess {
    public func deleteObject(key: String) async throws(UploadError) {
        let client: S3Client?
        do {
            client = try self.client()
        } catch {
            throw .setup(error)
        }
        guard let client else { throw .notConfigured }
        do {
            try await client.delete(key: key)
        } catch {
            throw .request(error)
        }
    }
}
