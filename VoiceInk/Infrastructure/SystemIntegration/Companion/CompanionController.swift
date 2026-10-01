// ENSO ad-hoc local override: VoiceInk Companion API v1 approved 2026-10-01 assumes one in-process
// server and an Application Support connection descriptor outside any Obsidian vault. Bundle/data
// layout or app multi-instance changes can make this stale; revalidate permissions, port ownership,
// isolated store roots, token rotation, and lifecycle before reuse/update.

import Foundation
import OSLog
import Security
import SwiftData
import Darwin

enum CompanionEnvironment {
    static let dataDirectoryVariable = "VOICEINK_COMPANION_DATA_DIR"
    static let portVariable = "VOICEINK_COMPANION_PORT"
    static let fixtureSeedVariable = "VOICEINK_COMPANION_SEED_FIXTURE"
    static let fixtureProviderURLVariable = "VOICEINK_COMPANION_FIXTURE_PROVIDER_URL"
    static let defaultPort: UInt16 = 62_741

    static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let rawOverride = environment[dataDirectoryVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOverride.isEmpty
        {
            let override = URL(fileURLWithPath: rawOverride, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard override.path.hasPrefix("/"),
                Bundle.main.bundleIdentifier?.hasSuffix(".CompanionTest") == true,
                !isInsideObsidianVault(override, fileManager: fileManager)
            else {
                throw CompanionAPIError(
                    status: "invalid_configuration",
                    message: "VOICEINK_COMPANION_DATA_DIR requires a CompanionTest bundle and a path outside Obsidian vaults"
                )
            }
            return override
        }

        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryName = Bundle.main.bundleIdentifier ?? "com.prakashjoshipax.VoiceInk"
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func port() throws -> UInt16 {
        guard let raw = ProcessInfo.processInfo.environment[portVariable], !raw.isEmpty else {
            return defaultPort
        }
        guard let value = UInt16(raw), value >= 1_024 else {
            throw CompanionAPIError(status: "invalid_configuration", message: "VOICEINK_COMPANION_PORT is invalid")
        }
        return value
    }

    static func recordingsDirectory(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func importInboxDirectory(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    private static func isInsideObsidianVault(_ url: URL, fileManager: FileManager) -> Bool {
        var candidate = url
        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".obsidian", isDirectory: true).path) {
                return true
            }
            candidate.deleteLastPathComponent()
        }
        return false
    }
}

@MainActor
final class CompanionController {
    private let server: CompanionHTTPServer
    private let service: CompanionAPIService
    private let descriptor: CompanionConnectionDescriptor
    private let descriptorURL: URL
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CompanionAPI")

    init(
        modelContext: ModelContext,
        engine: VoiceInkEngine,
        transcriptionModelManager: TranscriptionModelManager,
        whisperModelManager: WhisperModelManager,
        fluidAudioModelManager: FluidAudioModelManager,
        aiService: AIService,
        enhancementService: AIEnhancementService,
        recorderUIManager: RecorderUIManager,
        recordingShortcutManager: RecordingShortcutManager,
        updaterViewModel: UpdaterViewModel,
        menuBarManager: MenuBarManager
    ) throws {
        let root = try CompanionEnvironment.applicationSupportRoot()
        let companionDirectory = root.appendingPathComponent("Companion", isDirectory: true)
        try FileManager.default.createDirectory(
            at: companionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: companionDirectory.path)

        let port = try CompanionEnvironment.port()
        let token = try Self.generateToken()
        let service = CompanionAPIService(
            modelContext: modelContext,
            engine: engine,
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager,
            aiService: aiService,
            enhancementService: enhancementService,
            recorderUIManager: recorderUIManager,
            recordingShortcutManager: recordingShortcutManager,
            updaterViewModel: updaterViewModel,
            menuBarManager: menuBarManager,
            launchAtLoginManager: .shared,
            token: token
        )
        self.service = service
        server = try CompanionHTTPServer(port: port) { request in
            await service.handle(request)
        }
        descriptor = CompanionConnectionDescriptor(
            version: CompanionAPIService.version,
            endpoint: "http://127.0.0.1:\(port)",
            token: token
        )
        descriptorURL = companionDirectory.appendingPathComponent("connection.json", isDirectory: false)
    }

    func start() {
        let descriptor = descriptor
        let descriptorURL = descriptorURL
        let logger = logger
        server.start(
            onReady: {
                do {
                    try Self.writeConnectionDescriptor(descriptor, to: descriptorURL)
                } catch {
                    logger.error(
                        "Companion descriptor publication failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            },
            onFailure: { error in
                logger.error("Companion listener failed before publication: \(String(describing: error), privacy: .public)")
            }
        )
        logger.notice("Companion API lifecycle starting")
    }

    deinit {
        server.stop()
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CompanionAPIError(status: "token_generation_failed", message: "Could not create API credentials")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func writeConnectionDescriptor(
        _ descriptor: CompanionConnectionDescriptor,
        to url: URL
    ) throws {
        let data = try JSONEncoder.companion.encode(descriptor)
        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CompanionAPIError(status: "connection_file_failed", message: "Could not write API connection file")
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        guard rename(temporaryURL.path, url.path) == 0 else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
