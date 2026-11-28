import Foundation

public struct ProjectPart: Codable, Equatable, Sendable {
    public var screen: String
    public var camera: String?
    public var events: String
    public var screenStartHostTime: Double
    public var cameraStartHostTime: Double?

    public init(screen: String, camera: String?, events: String, screenStartHostTime: Double, cameraStartHostTime: Double?) {
        self.screen = screen
        self.camera = camera
        self.events = events
        self.screenStartHostTime = screenStartHostTime
        self.cameraStartHostTime = cameraStartHostTime
    }
}

public struct ProjectOverlays: Codable, Equatable, Sendable {
    public var clicks: Bool
    public var keys: Bool
    public var camera: Bool
    public var clickColorHex: String
    public var cameraMirrored: Bool

    public init(clicks: Bool, keys: Bool, camera: Bool, clickColorHex: String, cameraMirrored: Bool) {
        self.clicks = clicks
        self.keys = keys
        self.camera = camera
        self.clickColorHex = clickColorHex
        self.cameraMirrored = cameraMirrored
    }
}

public struct ProjectOutput: Codable, Equatable, Sendable {
    public var file: URL
    public var codec: VideoCodec
    public var frameRate: RecordingFrameRate
    public var capsToUHD: Bool

    public init(file: URL, codec: VideoCodec, frameRate: RecordingFrameRate, capsToUHD: Bool) {
        self.file = file
        self.codec = codec
        self.frameRate = frameRate
        self.capsToUHD = capsToUHD
    }
}

public enum ProjectError: LocalizedError, Equatable {
    case unsupportedVersion(found: Int, supported: Int, file: String)
    case unreadable(file: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(found, supported, file):
            "\(file) was saved by a newer Lunetta (project version \(found); this one reads version \(supported)). Update Lunetta to open it."
        case let .unreadable(file, reason):
            "Can't read \(file): \(reason)"
        }
    }
}

public struct RecordingProject: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var mode: RecordingMode
    public var region: CGRect
    public var windowID: UInt32?
    public var parts: [ProjectPart]
    public var overlays: ProjectOverlays
    public var output: ProjectOutput
    public var renderedAt: Date?

    public init(
        schemaVersion: Int = RecordingProject.currentSchemaVersion,
        id: UUID,
        createdAt: Date,
        mode: RecordingMode,
        region: CGRect,
        windowID: UInt32?,
        parts: [ProjectPart],
        overlays: ProjectOverlays,
        output: ProjectOutput,
        renderedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.region = region
        self.windowID = windowID
        self.parts = parts
        self.overlays = overlays
        self.output = output
        self.renderedAt = renderedAt
    }

    public static func decode(_ data: Data, file: String) throws(ProjectError) -> RecordingProject {
        struct VersionProbe: Decodable { var schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        do {
            let found = try decoder.decode(VersionProbe.self, from: data).schemaVersion
            guard found == currentSchemaVersion else {
                throw ProjectError.unsupportedVersion(found: found, supported: currentSchemaVersion, file: file)
            }
            return try decoder.decode(RecordingProject.self, from: data)
        } catch let error as ProjectError {
            throw error
        } catch {
            throw .unreadable(file: file, reason: String(describing: error))
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
