// ENSO ad-hoc local override: VoiceInk Companion API v1 approved 2026-10-01 assumes the current
// VoiceInkEngine, model managers, ModeManager, enhancement provider, and SwiftData entities.
// Upstream lifecycle/schema/service changes can make this stale; revalidate native effects,
// revision conflicts, model queuing, history/audio identity, and review provider behavior.

import Combine
import CryptoKit
import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import SwiftData

@MainActor
final class CompanionAPIService {
    static let version = "1"

    private let modelContext: ModelContext
    private let engine: VoiceInkEngine
    private let transcriptionModelManager: TranscriptionModelManager
    private let whisperModelManager: WhisperModelManager
    private let fluidAudioModelManager: FluidAudioModelManager
    private let aiService: AIService
    private let enhancementService: AIEnhancementService
    private let recorderUIManager: RecorderUIManager
    private let recordingShortcutManager: RecordingShortcutManager
    private let updaterViewModel: UpdaterViewModel
    private let menuBarManager: MenuBarManager
    private let launchAtLoginManager: LaunchAtLoginManager
    private let token: String
    private var pendingModelID: String?
    private var lastModelSelectionError: String?
    private var enhancementSelectionQueue = CompanionEnhancementSelectionQueue()
    private var lastEnhancementSelectionError: String?
    private var recordingStateObserver: AnyCancellable?
    private var audioTranscriptionObserver: AnyCancellable?
    private var artifacts: [String: CompanionArtifact] = [:]
    private var providerVerificationStatus: [String: String] = [:]
    private let shortcutRecorder = ShortcutRecorderModel()
    private var shortcutCapture = CompanionShortcutCaptureState(
        status: "idle", action: nil, display: nil, expiresAt: nil)
    private var shortcutCaptureAction: ShortcutAction?
    private var shortcutCaptureOriginal: Shortcut?
    private var shortcutCaptureTimeout: Task<Void, Never>?

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
        menuBarManager: MenuBarManager,
        launchAtLoginManager: LaunchAtLoginManager,
        token: String
    ) {
        self.modelContext = modelContext
        self.engine = engine
        self.transcriptionModelManager = transcriptionModelManager
        self.whisperModelManager = whisperModelManager
        self.fluidAudioModelManager = fluidAudioModelManager
        self.aiService = aiService
        self.enhancementService = enhancementService
        self.recorderUIManager = recorderUIManager
        self.recordingShortcutManager = recordingShortcutManager
        self.updaterViewModel = updaterViewModel
        self.menuBarManager = menuBarManager
        self.launchAtLoginManager = launchAtLoginManager
        self.token = token

        recordingStateObserver = engine.$recordingState.sink { [weak self] state in
            guard state == .idle else { return }
            Task { @MainActor [weak self] in self?.applyPendingSelectionsIfPossible() }
        }
        audioTranscriptionObserver = AudioTranscriptionManager.shared.$isProcessingQueue.sink { [weak self] isProcessing in
            guard !isProcessing else { return }
            Task { @MainActor [weak self] in self?.applyPendingSelectionsIfPossible() }
        }
    }

    func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard isAuthorized(request.headers["authorization"]) else {
            return error(401, "unauthorized", "A valid bearer token is required")
        }

        guard let components = URLComponents(string: "http://127.0.0.1\(request.target)") else {
            return error(400, "bad_request", "Invalid request target")
        }
        let path = components.path

        if request.method == "POST" {
            let contentType = request.headers["content-type"]?.lowercased() ?? ""
            guard contentType.hasPrefix("application/json") else {
                return error(415, "unsupported_media_type", "POST bodies must use application/json")
            }
        }

        do {
            switch (request.method, path) {
            case ("GET", "/v1/capabilities"):
                return try json(
                    CompanionCapabilityResponse(
                        version: Self.version,
                        sections: [
                            "Dashboard", "Modes", "AI Models", "Transcribe Audio", "History", "Audio",
                            "Dictionary", "Settings",
                        ],
                        actions: actionDescriptors().map(\.name),
                        actionDescriptors: actionDescriptors()
                    ))

            case ("GET", "/v1/state"):
                return try json(try stateResponse())

            case ("GET", "/v1/dictionary"):
                return try json(try dictionaryResponse())

            case ("POST", "/v1/dictionary"):
                let mutation = try decode(CompanionDictionaryMutationRequest.self, from: request.body)
                return try json(try mutateDictionary(mutation))

            case ("GET", "/v1/history"):
                return try json(try historyResponse(components: components))

            case ("POST", "/v1/settings"):
                let mutation = try decode(CompanionSettingMutationRequest.self, from: request.body)
                return try json(try mutateSetting(mutation))

            case ("POST", "/v1/models/select"):
                let selection = try decode(CompanionModelSelectionRequest.self, from: request.body)
                let response = try selectModel(selection.id)
                return try json(response, statusCode: response.status == "pending" ? 202 : 200)

            case ("POST", "/v1/actions"):
                let action = try decode(CompanionActionRequest.self, from: request.body)
                return try json(try await performAction(action))

            case ("POST", "/v1/review"):
                let review = try decode(CompanionReviewRequest.self, from: request.body)
                return try json(try await reviewSuggestions(review))

            default:
                if request.method == "GET", path.hasPrefix("/v1/history/"), path.hasSuffix("/audio") {
                    return try audioResponse(path: path)
                }
                if request.method == "GET", path.hasPrefix("/v1/artifacts/") {
                    return try artifactResponse(path: path)
                }
                return error(404, "not_found", "Unknown API endpoint")
            }
        } catch let routeError as CompanionRouteError {
            return error(routeError.statusCode, routeError.status, routeError.message)
        } catch is DecodingError {
            return error(400, "invalid_json", "Request JSON does not match the endpoint contract")
        } catch {
            return self.error(500, "internal_error", "The native operation failed")
        }
    }

    private func stateResponse() throws -> CompanionStateResponse {
        let dictionary = try dictionaryResponse()
        let historyCount = try modelContext.fetchCount(FetchDescriptor<Transcription>())
        let selectedID = transcriptionModelManager.currentTranscriptionModel.map(modelID)
        return CompanionStateResponse(
            version: Self.version,
            recordingState: recordingStateName(engine.recordingState),
            settings: settingDescriptors(),
            models: modelDescriptors(),
            refinementModel: refinementModelDescriptor(),
            modes: modeDescriptors(),
            providers: providerDescriptors(),
            prompts: promptDescriptors(),
            audioInput: audioInputState(),
            shortcuts: shortcutDescriptors(),
            shortcutCapture: shortcutCapture,
            audioTranscription: audioTranscriptionState(),
            metadata: CompanionStateMetadata(
                pendingModelID: pendingModelID,
                pendingEnhancementSelection: enhancementSelectionQueue.pending,
                activeTranscriptionModelID: selectedID,
                historyCount: historyCount,
                dictionaryRevision: dictionary.revision
            ),
            progress: selectionProgress(),
            dashboard: try dashboardState(),
            audio: audioState(),
            backup: CompanionBackupState(
                categories: ["general", "prompts", "modes", "dictionary", "customModels"],
                maximumImportBytes: 1_048_576
            ),
            license: licenseState()
        )
    }

    private func dashboardState() throws -> CompanionDashboardState {
        let summary = DashboardStatsCache.shared.currentSummary()
        let metadata = DashboardStatsCache.shared.currentMetadata()
        return CompanionDashboardState(
            summary: try summary.map(dashboardSummary),
            generatedAt: metadata?.generatedAt,
            sourceMetricCount: metadata?.metricCount ?? 0,
            isStale: DashboardStatsSnapshotStore.shared.isMarkedStale(),
            displayName: String(
                (UserDefaults.standard.string(forKey: "dashboardDisplayName") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(32)
            ),
            permissions: CompanionPermissionsState(
                accessibility: permission(AXIsProcessTrusted(), grantedStatus: "granted", deniedStatus: "denied"),
                microphone: microphonePermission(),
                screenCapture: permission(
                    CGPreflightScreenCaptureAccess(), grantedStatus: "granted", deniedStatus: "denied")
            )
        )
    }

    private func dashboardSummary(_ summary: DashboardStatsSummary) throws -> CompanionDashboardSummary {
        func period(_ value: DashboardInsightPeriod) throws -> CompanionDashboardPeriodState {
            let totals = summary.totals(for: value)
            return CompanionDashboardPeriodState(
                totalCount: totals.count,
                totalWords: totals.words,
                totalDuration: totals.duration,
                productivity: try companionJSONValue(summary.productivity(for: value)),
                modelUsage: try companionJSONValue(summary.modelUsage(for: value)),
                modelPerformance: try companionJSONValue(summary.modelPerformance(for: value)),
                peakHours: try companionJSONValue(summary.peakHours(for: value))
            )
        }
        return try CompanionDashboardSummary(
            today: period(.today),
            lastSevenDays: period(.lastSevenDays),
            lastThirtyDays: period(.lastThirtyDays),
            thisYear: period(.thisYear),
            allTime: period(.allTime)
        )
    }

    private func microphonePermission() -> CompanionPermissionDescriptor {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return permission(true, grantedStatus: "granted", deniedStatus: "denied")
        case .denied, .restricted: return permission(false, grantedStatus: "granted", deniedStatus: "denied")
        case .notDetermined: return CompanionPermissionDescriptor(status: "notDetermined", granted: false)
        @unknown default: return CompanionPermissionDescriptor(status: "unknown", granted: false)
        }
    }

    private func permission(
        _ granted: Bool, grantedStatus: String, deniedStatus: String
    ) -> CompanionPermissionDescriptor {
        CompanionPermissionDescriptor(status: granted ? grantedStatus : deniedStatus, granted: granted)
    }

    private func audioState() -> CompanionAudioState {
        let manager = AudioDeviceManager.shared
        return CompanionAudioState(
            input: audioInputState(),
            prioritizedDeviceUIDs: manager.prioritizedDevices.sorted { $0.priority < $1.priority }.map(\.id),
            pauseMediaDuringRecording: PlaybackController.shared.isPauseMediaEnabled,
            muteSystemDuringRecording: MediaController.shared.isSystemMuteEnabled,
            audioResumptionDelay: MediaController.shared.audioResumptionDelay,
            startSound: soundState(.start),
            stopSound: soundState(.stop)
        )
    }

    private func soundState(_ type: CustomSoundManager.SoundType) -> CompanionSoundState {
        let manager = CustomSoundManager.shared
        switch manager.soundSelection(for: type) {
        case .none:
            return CompanionSoundState(selection: "none", builtInID: nil, customConfigured: false)
        case .builtIn(let sound):
            return CompanionSoundState(selection: "builtIn", builtInID: sound.rawValue, customConfigured: false)
        case .custom:
            return CompanionSoundState(selection: "custom", builtInID: nil, customConfigured: true)
        }
    }

    private func licenseState() -> CompanionLicenseState {
        switch LicenseViewModel.shared.licenseState {
        case .licensed:
            return CompanionLicenseState(status: "licensed", isPro: true, trialDaysRemaining: nil)
        case .trial(let days):
            return CompanionLicenseState(status: "trial", isPro: true, trialDaysRemaining: days)
        case .trialExpired:
            return CompanionLicenseState(status: "trialExpired", isPro: false, trialDaysRemaining: 0)
        case .unlicensed:
            return CompanionLicenseState(status: "unlicensed", isPro: false, trialDaysRemaining: nil)
        }
    }

    private func dictionaryResponse() throws -> CompanionDictionaryResponse {
        let vocabulary = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
            .sorted { lhs, rhs in
                if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
                return lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
            }
            .map {
                CompanionVocabularyItem(id: vocabularyID($0.word), word: $0.word, dateAdded: $0.dateAdded)
            }
        let replacements = try modelContext.fetch(FetchDescriptor<WordReplacement>())
            .sorted { lhs, rhs in
                if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map {
                CompanionReplacementItem(
                    id: $0.id.uuidString,
                    originalText: $0.originalText,
                    replacementText: $0.replacementText,
                    isEnabled: $0.isEnabled,
                    dateAdded: $0.dateAdded
                )
            }
        let canonical = CompanionDictionaryCanonical(vocabulary: vocabulary, replacements: replacements)
        let canonicalData = try JSONEncoder.companion.encode(canonical)
        return CompanionDictionaryResponse(
            revision: SHA256.hash(data: canonicalData).hexString,
            vocabulary: vocabulary,
            replacements: replacements
        )
    }

    private func mutateDictionary(_ request: CompanionDictionaryMutationRequest) throws -> CompanionDictionaryResponse {
        guard !request.operations.isEmpty, request.operations.count <= 500 else {
            throw CompanionRouteError(400, "invalid_operations", "Dictionary mutation requires 1 to 500 operations")
        }
        let before = try dictionaryResponse()
        guard constantTimeEqual(request.expectedRevision, before.revision) else {
            throw CompanionRouteError(409, "revision_conflict", "Dictionary revision no longer matches")
        }

        do {
            for operation in request.operations {
                switch (operation.kind, operation.action) {
                case ("vocabulary", "upsert"):
                    try upsertVocabulary(operation)
                case ("vocabulary", "delete"):
                    try deleteVocabulary(operation)
                case ("replacement", "upsert"):
                    try upsertReplacement(operation)
                case ("replacement", "delete"):
                    try deleteReplacement(operation)
                default:
                    throw CompanionRouteError(400, "invalid_operation", "Unknown dictionary kind or action")
                }
            }
            if modelContext.hasChanges { try modelContext.save() }
        } catch {
            modelContext.rollback()
            throw error
        }
        return try dictionaryResponse()
    }

    private func upsertVocabulary(_ operation: CompanionDictionaryOperation) throws {
        let word = try validatedText(operation.word, field: "word", maximum: 500)
        let items = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
        let requestedID = operation.id
        let existing = items.first {
            (requestedID != nil && vocabularyID($0.word) == requestedID)
                || $0.word.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if let existing {
            if existing.word != word { existing.word = word }
        } else {
            modelContext.insert(VocabularyWord(word: word))
        }
    }

    private func deleteVocabulary(_ operation: CompanionDictionaryOperation) throws {
        guard operation.id != nil || operation.word != nil else {
            throw CompanionRouteError(400, "invalid_operation", "Vocabulary delete requires id or word")
        }
        let items = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
        let word = operation.word?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = items.filter {
            (operation.id != nil && vocabularyID($0.word) == operation.id)
                || (word != nil && $0.word.compare(word!, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame)
        }
        matches.forEach(modelContext.delete)
    }

    private func upsertReplacement(_ operation: CompanionDictionaryOperation) throws {
        let original = try validatedText(operation.originalText, field: "originalText", maximum: 2_000)
        let replacement = try validatedText(operation.replacementText, field: "replacementText", maximum: 2_000)
        let items = try modelContext.fetch(FetchDescriptor<WordReplacement>())
        let requestedUUID = operation.id.flatMap(UUID.init(uuidString:))
        if operation.id != nil, requestedUUID == nil {
            throw CompanionRouteError(400, "invalid_id", "Replacement id must be a UUID")
        }
        let existing = items.first {
            (requestedUUID != nil && $0.id == requestedUUID)
                || ($0.originalText == original && $0.replacementText == replacement)
        }
        let requestedTokens = replacementTokens(original)
        guard !requestedTokens.isEmpty else {
            throw CompanionRouteError(422, "invalid_replacement", "Replacement original text has no usable tokens")
        }
        let conflictingToken = items.lazy
            .filter { $0.id != existing?.id }
            .flatMap { self.replacementTokens($0.originalText) }
            .first { requestedTokens.contains($0) }
        guard conflictingToken == nil else {
            throw CompanionRouteError(
                409, "replacement_conflict",
                "One or more original terms already exist in word replacements")
        }
        if let existing {
            existing.originalText = original
            existing.replacementText = replacement
            existing.isEnabled = operation.isEnabled ?? existing.isEnabled
        } else {
            let item = WordReplacement(
                originalText: original,
                replacementText: replacement,
                isEnabled: operation.isEnabled ?? true
            )
            if let requestedUUID { item.id = requestedUUID }
            modelContext.insert(item)
        }
    }

    private func replacementTokens(_ original: String) -> Set<String> {
        Set(
            original.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private func deleteReplacement(_ operation: CompanionDictionaryOperation) throws {
        guard let rawID = operation.id, let id = UUID(uuidString: rawID) else {
            throw CompanionRouteError(400, "invalid_id", "Replacement delete requires a UUID id")
        }
        let items = try modelContext.fetch(FetchDescriptor<WordReplacement>())
        items.filter { $0.id == id }.forEach(modelContext.delete)
    }

    private func historyResponse(components: URLComponents) throws -> CompanionHistoryResponse {
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard item.name == "offset" || item.name == "limit" || item.name == "query",
                query[item.name] == nil
            else {
                throw CompanionRouteError(400, "invalid_query", "History query keys must be unique and supported")
            }
            query[item.name] = item.value ?? ""
        }
        let offset = try boundedInteger(query["offset"] ?? "0", field: "offset", range: 0...Int.max)
        let limit = try boundedInteger(query["limit"] ?? "100", field: "limit", range: 1...500)
        let search = query["query"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (search?.count ?? 0) <= 500 else {
            throw CompanionRouteError(422, "invalid_query", "History search is limited to 500 characters")
        }
        let fetched = try modelContext.fetch(FetchDescriptor<Transcription>())
        let filtered = fetched.filter {
            guard let search, !search.isEmpty else { return true }
            return $0.text.localizedCaseInsensitiveContains(search)
                || ($0.enhancedText?.localizedCaseInsensitiveContains(search) == true)
                || ($0.modeName?.localizedCaseInsensitiveContains(search) == true)
                || ($0.transcriptionModelName?.localizedCaseInsensitiveContains(search) == true)
        }
        let all = filtered.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        let start = min(offset, all.count)
        let end = min(start + limit, all.count)
        let items = all[start..<end].map {
            let hasAudio = hasReadableAudio($0.audioFileURL)
            return CompanionHistoryItem(
                id: $0.id.uuidString,
                text: $0.text,
                enhancedText: $0.enhancedText,
                timestamp: $0.timestamp,
                duration: $0.duration,
                hasAudio: hasAudio,
                audioFileURL: hasAudio ? "/v1/history/\($0.id.uuidString)/audio" : nil,
                audioFileExtension: hasAudio ? portableAudioExtension($0.audioFileURL) : nil,
                transcriptionDuration: $0.transcriptionDuration,
                enhancementDuration: $0.enhancementDuration,
                transcriptionModelName: $0.transcriptionModelName,
                aiEnhancementModelName: $0.aiEnhancementModelName,
                promptName: $0.promptName,
                modeName: $0.modeName,
                transcriptionStatus: $0.transcriptionStatus
            )
        }
        return CompanionHistoryResponse(
            items: Array(items), nextOffset: end < all.count ? end : nil, total: all.count, query: search)
    }

    private func hasReadableAudio(_ storedURL: String?) -> Bool {
        guard let storedURL, let url = URL(string: storedURL), url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func portableAudioExtension(_ storedURL: String?) -> String? {
        guard let storedURL, let url = URL(string: storedURL) else { return nil }
        let value = url.pathExtension.lowercased()
        return ["wav", "m4a", "mp3", "aac", "flac", "aiff", "aif", "ogg", "mp4"].contains(value)
            ? value : nil
    }

    private func audioResponse(path: String) throws -> CompanionHTTPResponse {
        let components = path.split(separator: "/")
        guard components.count == 4, components[0] == "v1", components[1] == "history",
            components[3] == "audio"
        else {
            throw CompanionRouteError(404, "not_found", "Unknown audio endpoint")
        }
        guard let id = UUID(uuidString: String(components[2])) else {
            throw CompanionRouteError(400, "invalid_id", "History id must be a UUID")
        }
        let transcriptions = try modelContext.fetch(FetchDescriptor<Transcription>())
        guard let transcription = transcriptions.first(where: { $0.id == id }),
            let storedURL = transcription.audioFileURL,
            let url = URL(string: storedURL), url.isFileURL
        else {
            throw CompanionRouteError(404, "audio_not_found", "This transcription has no audio file")
        }
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CompanionRouteError(404, "audio_not_found", "This transcription audio file is unavailable")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 256 * 1_024 * 1_024 else {
            throw CompanionRouteError(413, "audio_too_large", "Audio exceeds the 256 MiB API response limit")
        }
        let data = try Data(contentsOf: resolvedURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).hexString
        return CompanionHTTPResponse(
            statusCode: 200,
            contentType: audioContentType(extension: resolvedURL.pathExtension),
            body: data,
            headers: [
                "Content-Disposition": "attachment; filename=\"\(id.uuidString).\(safeExtension(resolvedURL.pathExtension))\"",
                "X-Content-SHA256": digest,
                "X-VoiceInk-Transcription-ID": id.uuidString,
            ]
        )
    }

    private func artifactResponse(path: String) throws -> CompanionHTTPResponse {
        artifacts = artifacts.filter { $0.value.expiresAt > Date() }
        let components = path.split(separator: "/")
        guard components.count == 3, components[0] == "v1", components[1] == "artifacts",
            let artifact = artifacts[String(components[2])]
        else {
            throw CompanionRouteError(404, "artifact_not_found", "Artifact is missing or expired")
        }
        return CompanionHTTPResponse(
            statusCode: 200,
            contentType: artifact.contentType,
            body: artifact.data,
            headers: ["Content-Disposition": "attachment; filename=\"\(artifact.filename)\""]
        )
    }

    private func settingDescriptors() -> [CompanionSettingDescriptor] {
        let defaults = UserDefaults.standard
        let languageOptions = transcriptionModelManager.currentTranscriptionModel.map {
            Array($0.supportedLanguages.keys).sorted()
        } ?? []
        return [
            setting("SelectedLanguage", "Transcription Language", "string", .string(defaults.string(forKey: "SelectedLanguage") ?? "en"), languageOptions, "Transcription"),
            setting("IsTextFormattingEnabled", "Text Formatting", "boolean", .bool(defaults.bool(forKey: "IsTextFormattingEnabled")), nil, "Transcription"),
            setting("IsVADEnabled", "Voice Activity Detection", "boolean", .bool(defaults.bool(forKey: "IsVADEnabled")), nil, "Transcription"),
            setting("AppendTrailingSpace", "Append Trailing Space", "boolean", .bool(defaults.bool(forKey: "AppendTrailingSpace")), nil, "Output"),
            setting("restoreClipboardAfterPaste", "Restore Clipboard", "boolean", .bool(defaults.bool(forKey: "restoreClipboardAfterPaste")), nil, "Output"),
            setting("clipboardRestoreDelay", "Clipboard Restore Delay", "number", .number(defaults.double(forKey: "clipboardRestoreDelay")), nil, "Output"),
            setting(RecorderDisplaySettingsKeys.showLiveTranscript, "Show Live Transcript", "boolean", .bool(defaults.bool(forKey: RecorderDisplaySettingsKeys.showLiveTranscript)), nil, "Interface"),
            setting("enableAnnouncements", "Enable Announcements", "boolean", .bool(defaults.bool(forKey: "enableAnnouncements")), nil, "Interface"),
            setting(CleanupSettingsKeys.isAudioCleanupEnabled, "Automatic Audio Cleanup", "boolean", .bool(defaults.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)), nil, "Retention"),
            setting(CleanupSettingsKeys.audioRetentionPeriod, "Audio Retention Days", "number", .number(Double(defaults.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod))), nil, "Retention"),
            setting(CleanupSettingsKeys.isTranscriptionCleanupEnabled, "Automatic Transcription Cleanup", "boolean", .bool(defaults.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)), nil, "Retention"),
            setting(CleanupSettingsKeys.transcriptionRetentionMinutes, "Transcription Retention Minutes", "number", .number(Double(defaults.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes))), nil, "Retention"),
            setting(AppAppearancePreference.userDefaultsKey, "Appearance", "string", .string(AppAppearancePreference.stored.rawValue), AppAppearancePreference.allCases.map(\.rawValue), "Interface"),
            setting(AppLanguagePreference.userDefaultsKey, "Language", "string", .string(AppLanguagePreference.storedRawValue), AppLanguagePreference.availableOptions.map(\.id), "Interface"),
            setting("RecorderType", "Recorder Style", "string", .string(recorderUIManager.recorderPanelStyle.rawValue), RecorderPanelStyle.allCases.map(\.rawValue), "Interface"),
            setting("LaunchAtLogin", "Launch at Login", "boolean", .bool(launchAtLoginManager.isEnabled), nil, "General"),
            setting("IsMenuBarOnly", "Hide Dock Icon", "boolean", .bool(menuBarManager.isMenuBarOnly), nil, "General"),
            setting(PasteMethod.userDefaultsKey, "Paste Method", "string", .string(PasteMethod.current().rawValue), PasteMethod.allCases.map(\.rawValue), "Pasting"),
            setting("isPauseMediaEnabled", "Pause Media During Recording", "boolean", .bool(PlaybackController.shared.isPauseMediaEnabled), nil, "Audio"),
            setting("isSystemMuteEnabled", "Mute System During Recording", "boolean", .bool(MediaController.shared.isSystemMuteEnabled), nil, "Audio"),
            setting("audioResumptionDelay", "Audio Resumption Delay", "number", .number(MediaController.shared.audioResumptionDelay), nil, "Audio"),
            setting("SkipShortEnhancement", "Skip Short Enhancement", "boolean", .bool(defaults.bool(forKey: "SkipShortEnhancement")), nil, "Enhancement"),
            setting("ShortEnhancementWordThreshold", "Short Enhancement Word Threshold", "number", .number(Double(defaults.integer(forKey: "ShortEnhancementWordThreshold"))), nil, "Enhancement"),
            setting(EnhancementRequestSettings.timeoutKey, "Enhancement Timeout", "number", .number(Double(EnhancementRequestSettings.timeout)), nil, "Enhancement"),
            setting(EnhancementRequestSettings.retryOnTimeoutKey, "Retry Enhancement on Timeout", "boolean", .bool(EnhancementRequestSettings.retryOnTimeout), nil, "Enhancement"),
            setting("PrewarmModelOnWake", "Prewarm Model on Wake", "boolean", .bool(defaults.bool(forKey: "PrewarmModelOnWake")), nil, "Transcription"),
            setting(CloudTranscriptionSettings.timeoutKey, "Cloud Transcription Timeout", "number", .number(CloudTranscriptionSettings.timeout), nil, "Transcription"),
            setting("PrimaryRecordingShortcutMode", "Primary Shortcut Mode", "string", .string(recordingShortcutManager.primaryRecordingShortcutMode.rawValue), RecordingShortcutManager.Mode.allCases.map(\.rawValue), "Shortcuts"),
            setting("SecondaryRecordingShortcutMode", "Secondary Shortcut Mode", "string", .string(recordingShortcutManager.secondaryRecordingShortcutMode.rawValue), RecordingShortcutManager.Mode.allCases.map(\.rawValue), "Shortcuts"),
            setting("SecondaryRecordingShortcut", "Secondary Shortcut", "string", .string(recordingShortcutManager.secondaryRecordingShortcut.rawValue), RecordingShortcutManager.ShortcutSelection.allCases.map(\.rawValue), "Shortcuts"),
            setting("VoiceInkChecksForUpdatesOnLaunch", "Automatically Check for Updates", "boolean", .bool(updaterViewModel.checksForUpdatesWhenDashboardAppears), nil, "General"),
            setting("dashboardDisplayName", "Dashboard Display Name", "string", .string(defaults.string(forKey: "dashboardDisplayName") ?? ""), nil, "Dashboard"),
            setting("WhisperPrompts", "Whisper Prompts", "object", .object(
                Dictionary(uniqueKeysWithValues: languageOptions.map {
                    ($0, .string(whisperModelManager.whisperPrompt.getLanguagePrompt(for: $0)))
                })
            ), nil, "Transcription"),
        ]
    }

    private func mutateSetting(_ request: CompanionSettingMutationRequest) throws -> CompanionSettingDescriptor {
        let defaults = UserDefaults.standard
        switch (request.key, request.value) {
        case ("SelectedLanguage", .string(let value)):
            let allowed = transcriptionModelManager.currentTranscriptionModel.map { Set($0.supportedLanguages.keys) } ?? []
            guard allowed.isEmpty || allowed.contains(value) else {
                throw CompanionRouteError(422, "invalid_value", "Language is unsupported by the selected model")
            }
            defaults.set(value, forKey: request.key)
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        case ("IsTextFormattingEnabled", .bool(let value)),
            ("IsVADEnabled", .bool(let value)),
            ("AppendTrailingSpace", .bool(let value)),
            ("restoreClipboardAfterPaste", .bool(let value)),
            (RecorderDisplaySettingsKeys.showLiveTranscript, .bool(let value)):
            defaults.set(value, forKey: request.key)
        case ("enableAnnouncements", .bool(let value)):
            defaults.set(value, forKey: request.key)
            value ? AnnouncementsService.shared.start() : AnnouncementsService.shared.stop()
        case ("clipboardRestoreDelay", .number(let value)):
            guard value.isFinite, (0...10).contains(value) else {
                throw CompanionRouteError(422, "invalid_value", "Clipboard delay must be from 0 to 10 seconds")
            }
            defaults.set(value, forKey: request.key)
        case (CleanupSettingsKeys.isAudioCleanupEnabled, .bool(let value)):
            if value && defaults.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) {
                throw CompanionRouteError(409, "cleanup_conflict", "Audio cleanup cannot run with transcription cleanup")
            }
            defaults.set(value, forKey: request.key)
            if value {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            } else {
                AudioCleanupManager.shared.stopAutomaticCleanup()
            }
        case (CleanupSettingsKeys.isTranscriptionCleanupEnabled, .bool(let value)):
            defaults.set(value, forKey: request.key)
            if value {
                defaults.set(false, forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
                AudioCleanupManager.shared.stopAutomaticCleanup()
            } else if defaults.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled) {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            }
        case (CleanupSettingsKeys.audioRetentionPeriod, .number(let value)):
            let integer = try exactInteger(value, range: 1...3650, field: request.key)
            defaults.set(integer, forKey: request.key)
        case (CleanupSettingsKeys.transcriptionRetentionMinutes, .number(let value)):
            let integer = try exactInteger(value, range: 1...525_600, field: request.key)
            defaults.set(integer, forKey: request.key)
        case (AppAppearancePreference.userDefaultsKey, .string(let value)):
            guard let preference = AppAppearancePreference(rawValue: value) else {
                throw CompanionRouteError(422, "invalid_value", "Unknown appearance")
            }
            defaults.set(value, forKey: request.key)
            preference.apply()
        case (AppLanguagePreference.userDefaultsKey, .string(let value)):
            let normalized = AppLanguagePreference.normalizedRawValue(value)
            guard normalized == value else {
                throw CompanionRouteError(422, "invalid_value", "Unknown app language")
            }
            defaults.set(value, forKey: request.key)
            AppLanguagePreference.apply(rawValue: value)
        case ("RecorderType", .string(let value)):
            guard let style = RecorderPanelStyle(rawValue: value) else {
                throw CompanionRouteError(422, "invalid_value", "Unknown recorder style")
            }
            recorderUIManager.recorderPanelStyle = style
        case ("LaunchAtLogin", .bool(let value)):
            launchAtLoginManager.setEnabled(value)
        case ("IsMenuBarOnly", .bool(let value)):
            menuBarManager.isMenuBarOnly = value
        case (PasteMethod.userDefaultsKey, .string(let value)):
            guard let method = PasteMethod(rawValue: value) else {
                throw CompanionRouteError(422, "invalid_value", "Unknown paste method")
            }
            PasteMethod.setCurrent(method)
        case ("isPauseMediaEnabled", .bool(let value)):
            PlaybackController.shared.isPauseMediaEnabled = value
        case ("isSystemMuteEnabled", .bool(let value)):
            MediaController.shared.isSystemMuteEnabled = value
        case ("audioResumptionDelay", .number(let value)):
            guard value.isFinite, (0...10).contains(value) else {
                throw CompanionRouteError(422, "invalid_value", "Audio resumption delay must be from 0 to 10 seconds")
            }
            MediaController.shared.audioResumptionDelay = value
        case ("SkipShortEnhancement", .bool(let value)),
            (EnhancementRequestSettings.retryOnTimeoutKey, .bool(let value)),
            ("PrewarmModelOnWake", .bool(let value)):
            defaults.set(value, forKey: request.key)
        case ("ShortEnhancementWordThreshold", .number(let value)):
            defaults.set(try exactInteger(value, range: 1...15, field: request.key), forKey: request.key)
        case (EnhancementRequestSettings.timeoutKey, .number(let value)):
            defaults.set(try exactInteger(value, range: 3...60, field: request.key), forKey: request.key)
        case (CloudTranscriptionSettings.timeoutKey, .number(let value)):
            defaults.set(try exactInteger(value, range: 10...1800, field: request.key), forKey: request.key)
        case ("PrimaryRecordingShortcutMode", .string(let value)):
            guard let mode = RecordingShortcutManager.Mode(rawValue: value) else {
                throw CompanionRouteError(422, "invalid_value", "Unknown shortcut mode")
            }
            recordingShortcutManager.primaryRecordingShortcutMode = mode
        case ("SecondaryRecordingShortcutMode", .string(let value)):
            guard let mode = RecordingShortcutManager.Mode(rawValue: value) else {
                throw CompanionRouteError(422, "invalid_value", "Unknown shortcut mode")
            }
            recordingShortcutManager.secondaryRecordingShortcutMode = mode
        case ("SecondaryRecordingShortcut", .string(let value)):
            guard let selection = RecordingShortcutManager.ShortcutSelection(rawValue: value) else {
                throw CompanionRouteError(422, "invalid_value", "Unknown shortcut selection")
            }
            recordingShortcutManager.secondaryRecordingShortcut = selection
        case ("VoiceInkChecksForUpdatesOnLaunch", .bool(let value)):
            updaterViewModel.setChecksForUpdatesWhenDashboardAppears(value)
        case ("dashboardDisplayName", .string(let value)):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count <= 32 else {
                throw CompanionRouteError(422, "invalid_value", "Dashboard display name is limited to 32 characters")
            }
            defaults.set(normalized, forKey: request.key)
        default:
            throw CompanionRouteError(400, "invalid_setting", "Unknown setting or invalid value type")
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        guard let descriptor = settingDescriptors().first(where: { $0.key == request.key }) else {
            throw CompanionRouteError(500, "setting_readback_failed", "Setting could not be read back")
        }
        return descriptor
    }

    private func modelDescriptors() -> [CompanionModelDescriptor] {
        let usableIDs = Set(transcriptionModelManager.usableModels.map(modelID))
        let selectedID = transcriptionModelManager.currentTranscriptionModel.map(modelID)
        return transcriptionModelManager.allAvailableModels.enumerated().map { index, model in
            let id = modelID(model)
            let download = modelDownloadState(model)
            let custom = model is CustomCloudModel || model is ImportedWhisperModel
            return CompanionModelDescriptor(
                id: id,
                order: index + 1,
                name: model.name,
                provider: model.provider.rawValue,
                builtin: !custom,
                platform: model.provider == .nativeApple ? "macOS 26+" : nil,
                onDevice: [.whisper, .fluidAudio, .transcribeCpp, .nativeApple].contains(model.provider),
                available: transcriptionModelManager.isAvailableOnCurrentOS(model),
                downloaded: usableIDs.contains(id),
                selected: selectedID == id,
                downloading: download.downloading,
                downloadProgress: download.progress,
                deletable: download.local && usableIDs.contains(id),
                displayName: model.displayName,
                description: model.description,
                languages: model.supportedLanguages,
                multilingual: model.isMultilingualModel,
                streaming: model.supportsStreaming,
                size: modelMetrics(model).size,
                speed: modelMetrics(model).speed,
                accuracy: modelMetrics(model).accuracy,
                ramUsage: modelMetrics(model).ramUsage,
                publisher: modelMetrics(model).publisher,
                custom: custom,
                keyConfigured: (model as? CustomCloudModel).map { !$0.apiKey.isEmpty } ?? false,
                verificationStatus: nil
            )
        }
    }

    private func refinementModelDescriptor() -> CompanionRefinementModelDescriptor {
        let service = aiService.voiceInkRefineService
        let availabilityStatus: String
        switch service.availability {
        case .available: availabilityStatus = "available"
        case .unsupportedIntel: availabilityStatus = "unsupportedIntel"
        case .insufficientMemory: availabilityStatus = "insufficientMemory"
        }

        let downloadStatus: String
        if service.isDownloading {
            downloadStatus = service.isFinalizingDownload ? "finalizing" : "downloading"
        } else if service.isDownloaded {
            downloadStatus = "downloaded"
        } else if service.downloadError != nil {
            downloadStatus = "failed"
        } else if service.availability != .available {
            downloadStatus = "unavailable"
        } else {
            downloadStatus = "notDownloaded"
        }

        var supportedActions: [String] = []
        if service.isDownloading {
            supportedActions.append("cancelRefinementModelDownload")
        } else if service.isDownloaded {
            supportedActions.append("deleteRefinementModel")
        } else if service.availability == .available {
            supportedActions.append("downloadRefinementModel")
        }
        if service.isAvailableInModes {
            supportedActions.append(contentsOf: ["selectEnhancementProvider", "selectEnhancementModel"])
        }

        return CompanionRefinementModelDescriptor(
            id: refinementModelID,
            order: 0,
            name: VoiceInkRefineService.modelName,
            displayName: VoiceInkRefineService.modelName,
            provider: VoiceInkRefineService.providerName,
            kind: "enhancement",
            badge: "New",
            description: "Cleans up raw transcripts. Processing stays on your Mac.",
            platform: "Apple silicon",
            onDevice: true,
            minimumMemoryBytes: VoiceInkRefineService.minimumMemoryBytes,
            size: VoiceInkRefineService.downloadSizeDescription,
            available: service.availability == .available,
            availabilityStatus: availabilityStatus,
            unavailableDescription: service.unavailableDescription,
            downloaded: service.isDownloaded,
            selected: aiService.selectedProvider == .voiceInkRefine,
            selectable: service.isAvailableInModes,
            downloading: service.isDownloading,
            finalizing: service.isFinalizingDownload,
            downloadProgress: service.isDownloading ? service.downloadProgress : (service.isDownloaded ? 1 : nil),
            downloadedBytes: service.downloadedBytes,
            totalDownloadBytes: service.totalDownloadBytes,
            downloadStatus: downloadStatus,
            deletable: service.isDownloaded && !service.isDownloading,
            supportedActions: supportedActions
        )
    }

    private var refinementModelID: String {
        "voiceink-refine-v1"
    }

    private func modeDescriptors() -> [CompanionModeDescriptor] {
        let manager = ModeManager.shared
        return manager.configurations.enumerated().map { order, mode in
            CompanionModeDescriptor(
                id: mode.id.uuidString,
                name: mode.name,
                isEnabled: mode.isEnabled,
                isDefault: mode.isDefault,
                isActive: manager.currentEffectiveConfiguration?.id == mode.id,
                transcriptionModelName: mode.selectedTranscriptionModelName,
                language: mode.selectedLanguage,
                enhancementEnabled: mode.isAIEnhancementEnabled,
                enhancementProvider: mode.selectedAIProvider,
                enhancementModel: mode.selectedAIModel,
                promptID: mode.selectedPrompt,
                isRealtimeTranscriptionEnabled: mode.isRealtimeTranscriptionEnabled,
                isTextFormattingEnabled: mode.isTextFormattingEnabled,
                useClipboardContext: mode.useClipboardContext,
                useSelectedTextContext: mode.useSelectedTextContext,
                useScreenCapture: mode.useScreenCapture,
                outputMode: mode.outputMode.rawValue,
                autoSendKey: mode.autoSendKey.rawValue,
                icon: (try? companionJSONValue(mode.icon)) ?? .null,
                order: order,
                appConfigs: (try? companionJSONValue(mode.appConfigs ?? [])) ?? .array([]),
                urlConfigs: (try? companionJSONValue(mode.urlConfigs ?? [])) ?? .array([]),
                triggerGroups: (try? companionJSONValue(mode.triggerGroups ?? [])) ?? .array([]),
                triggerWords: mode.triggerWords,
                customCommand: mode.customCommand?.command
            )
        }
    }

    private func providerDescriptors() -> [CompanionProviderDescriptor] {
        let connected = Set(aiService.connectedProviders)
        let standard = AIProvider.allCases.filter(\.supportsEnhancement).map { provider in
            let keyConfigured = !provider.requiresAPIKey
                || APIKeyManager.shared.hasAPIKey(forProvider: provider.rawValue)
            return CompanionProviderDescriptor(
                id: provider.rawValue,
                name: provider.rawValue,
                connected: connected.contains(provider),
                selected: aiService.selectedProvider == provider,
                models: aiService.availableModels(for: provider),
                selectedModel: aiService.selectedModel(for: provider),
                kind: "enhancement",
                baseURL: publicProviderBaseURL(provider.baseURL),
                requiresAPIKey: provider.requiresAPIKey,
                keyConfigured: keyConfigured,
                verificationStatus: providerVerificationStatus[provider.rawValue]
                    ?? (keyConfigured ? "configured" : "missingKey"),
                custom: false,
                enabled: true
            )
        }
        let customEnhancement = CustomAIProviderManager.shared.providers.map { provider in
            let id = "enhancement:\(provider.id.uuidString)"
            let keyConfigured =
                APIKeyManager.shared.getCustomAIProviderAPIKey(forProviderId: provider.id)?.isEmpty == false
            return CompanionProviderDescriptor(
                id: id,
                name: provider.name,
                connected: keyConfigured,
                selected: aiService.selectedProvider == .custom
                    && aiService.selectedModel(for: .custom) == provider.modelName,
                models: provider.trimmedModels,
                selectedModel: provider.modelName,
                kind: "enhancement",
                baseURL: publicProviderBaseURL(provider.baseURL),
                requiresAPIKey: true,
                keyConfigured: keyConfigured,
                verificationStatus: providerVerificationStatus[id]
                    ?? (keyConfigured ? "configured" : "missingKey"),
                custom: true,
                enabled: true
            )
        }
        let customTranscription = CustomCloudModelManager.shared.customModels.map { model in
            let id = "transcription:\(model.id.uuidString)"
            let keyConfigured = !model.apiKey.isEmpty
            return CompanionProviderDescriptor(
                id: id,
                name: model.displayName,
                connected: keyConfigured,
                selected: transcriptionModelManager.currentTranscriptionModel.map(modelID) == modelID(model),
                models: [model.modelName],
                selectedModel: model.modelName,
                kind: "transcription",
                baseURL: publicProviderBaseURL(model.apiEndpoint),
                requiresAPIKey: true,
                keyConfigured: keyConfigured,
                verificationStatus: providerVerificationStatus[id]
                    ?? (keyConfigured ? "configured" : "missingKey"),
                custom: true,
                enabled: true
            )
        }
        return standard + customEnhancement + customTranscription
    }

    private func publicProviderBaseURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }

    private func promptDescriptors() -> [CompanionPromptDescriptor] {
        enhancementService.allPrompts.map {
            CompanionPromptDescriptor(
                id: $0.id.uuidString,
                title: $0.title,
                promptText: $0.promptText,
                useSystemInstructions: $0.useSystemInstructions
            )
        }
    }

    private func audioInputState() -> CompanionAudioInputState {
        let manager = AudioDeviceManager.shared
        let selectedUID = manager.selectedDeviceID.flatMap { selectedID in
            manager.availableDevices.first(where: { $0.id == selectedID })?.uid
        }
        let devices = manager.availableDevices.map { device in
            let prioritized = manager.prioritizedDevices.first(where: { $0.id == device.uid })
            return CompanionAudioDeviceDescriptor(
                uid: device.uid,
                name: device.name,
                selected: device.uid == selectedUID,
                prioritized: prioritized != nil,
                priority: prioritized?.priority
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return CompanionAudioInputState(mode: manager.inputMode.rawValue, selectedUID: selectedUID, devices: devices)
    }

    private func shortcutDescriptors() -> [CompanionShortcutDescriptor] {
        shortcutActions().map { identifier, label, action in
            let shortcut = ShortcutStore.shortcut(for: action)
            return CompanionShortcutDescriptor(
                action: identifier,
                label: label,
                kind: shortcut?.kind.rawValue,
                keyCode: shortcut.map { Int($0.keyCode) },
                modifiers: shortcut.map { Double($0.modifierFlags.rawValue) },
                display: shortcut?.displayString ?? ""
            )
        }
    }

    private func shortcutActions() -> [(String, String, ShortcutAction)] {
        let fixed: [(String, ShortcutAction)] = [
            ("primaryRecording", .primaryRecording),
            ("secondaryRecording", .secondaryRecording),
            ("pasteLastTranscription", .pasteLastTranscription),
            ("pasteLastEnhancement", .pasteLastEnhancement),
            ("retryLastTranscription", .retryLastTranscription),
            ("cancelRecorder", .cancelRecorder),
            ("openQuickHistory", .openQuickHistory),
            ("quickAddToDictionary", .quickAddToDictionary),
        ]
        let modes = ModeManager.shared.configurations.map { ("mode:\($0.id.uuidString)", ShortcutAction.mode($0.id)) }
        return (fixed + modes).map { ($0.0, $0.1.displayName, $0.1) }
    }

    private func audioTranscriptionState() -> CompanionAudioTranscriptionState {
        let manager = AudioTranscriptionManager.shared
        let items = manager.queue.map { item -> CompanionAudioTranscriptionItem in
            let state: (String, String?)
            var errorMessage: String?
            switch item.status {
            case .pending: state = ("pending", nil)
            case .processing(let phase): state = ("processing", phase.rawValue)
            case .completed: state = ("completed", nil)
            case .failed(let message):
                state = ("failed", nil)
                errorMessage = String(message.prefix(500))
            }
            return CompanionAudioTranscriptionItem(
                id: item.id.uuidString,
                filename: item.filename,
                status: state.0,
                phase: state.1,
                transcriptionID: item.transcription?.id.uuidString,
                errorMessage: errorMessage
            )
        }
        return CompanionAudioTranscriptionState(isProcessing: manager.isProcessingQueue, items: items)
    }

    private func modelDownloadState(_ model: any TranscriptionModel) -> (downloading: Bool, progress: Double?, local: Bool) {
        if Bundle.main.bundleIdentifier?.hasSuffix(".CompanionTest") == true,
            model is FluidAudioModel || model is TranscribeCppModel
        {
            return (false, nil, false)
        }
        if let whisper = model as? WhisperModel {
            let values = [
                whisperModelManager.downloadProgress[whisper.name + "_main"],
                whisperModelManager.downloadProgress[whisper.name + "_coreml"],
            ].compactMap { $0 }
            return (!values.isEmpty, values.max(), true)
        }
        if let fluid = model as? FluidAudioModel {
            let status = fluidAudioModelManager.downloadStatus(for: fluid)
            return (fluidAudioModelManager.isFluidAudioModelDownloading(fluid), status?.fractionCompleted, true)
        }
        if let transcribe = model as? TranscribeCppModel {
            let manager = TranscribeCppModelManager.shared
            let status = manager.downloadStatus(for: transcribe)
            return (manager.isModelDownloading(transcribe), status?.fractionCompleted, true)
        }
        return (false, nil, false)
    }

    private func modelMetrics(
        _ model: any TranscriptionModel
    ) -> (size: String?, speed: Double?, accuracy: Double?, ramUsage: Double?, publisher: String?) {
        if let model = model as? FluidAudioModel {
            return (model.size, model.speed, model.accuracy, model.ramUsage, nil)
        }
        if let model = model as? TranscribeCppModel {
            return (model.size, model.speed, model.accuracy, model.ramUsage, model.publisher)
        }
        if let model = model as? WhisperModel {
            return (model.size, model.speed, model.accuracy, model.ramUsage, nil)
        }
        return (nil, nil, nil, nil, nil)
    }

    private func actionDescriptors() -> [CompanionActionDescriptor] {
        let providerOptions = AIProvider.allCases.filter(\.supportsEnhancement).map(\.rawValue)
        let shortcutOptions = shortcutActions().map(\.0)
        let sections = ["Dashboard", "Modes", "AI Models", "Transcribe Audio", "History", "Audio", "Dictionary", "Settings"]
        func arg(_ name: String, _ type: String, _ required: Bool = true, _ options: [String]? = nil) -> CompanionActionArgumentDescriptor {
            CompanionActionArgumentDescriptor(name: name, type: type, required: required, options: options)
        }
        func action(_ name: String, _ label: String, _ arguments: [CompanionActionArgumentDescriptor] = []) -> CompanionActionDescriptor {
            CompanionActionDescriptor(name: name, label: label, arguments: arguments)
        }
        return [
            action("openSection", "Open section", [arg("section", "string", true, sections)]),
            action("openLicenseWindow", "Open VoiceInk Pro"),
            action("checkForUpdates", "Check for updates"),
            action("resetOnboarding", "Reset onboarding"),
            action("selectEnhancementProvider", "Select enhancement provider", [arg("provider", "string", true, providerOptions)]),
            action("selectEnhancementModel", "Select enhancement model", [arg("provider", "string", true, providerOptions), arg("model", "string")]),
            action("upsertPrompt", "Create or update prompt", [arg("id", "string", false), arg("title", "string"), arg("promptText", "string"), arg("useSystemInstructions", "boolean")]),
            action("deletePrompt", "Delete prompt", [arg("id", "string")]),
            action("createMode", "Create mode", [arg("name", "string")]),
            action("updateMode", "Update mode", [arg("id", "string"), arg("name", "string", false), arg("isAIEnhancementEnabled", "boolean", false), arg("promptID", "string", false), arg("transcriptionModelName", "string", false), arg("language", "string", false), arg("isTextFormattingEnabled", "boolean", false), arg("enhancementProvider", "string", false, providerOptions), arg("enhancementModel", "string", false), arg("outputMode", "string", false, ModeOutputMode.allCases.map(\.rawValue)), arg("autoSendKey", "string", false, AutoSendKey.allCases.map(\.rawValue)), arg("isEnabled", "boolean", false), arg("isDefault", "boolean", false)]),
            action("deleteMode", "Delete mode", [arg("id", "string")]),
            action("setModeEnabled", "Enable or disable mode", [arg("id", "string"), arg("enabled", "boolean")]),
            action("setDefaultMode", "Set default mode", [arg("id", "string")]),
            action("setActiveMode", "Set active mode", [arg("id", "string")]),
            action("clearActiveMode", "Clear active mode"),
            action("selectAudioInputMode", "Select audio input mode", [arg("mode", "string", true, AudioInputMode.allCases.map(\.rawValue))]),
            action("selectMicrophone", "Select microphone", [arg("uid", "string")]),
            action("setShortcut", "Set shortcut", [arg("action", "string", true, shortcutOptions), arg("kind", "string", true, ["key", "modifierOnly", "mouseButton"]), arg("keyCode", "number"), arg("modifiers", "number")]),
            action("clearShortcut", "Clear shortcut", [arg("action", "string", true, shortcutOptions)]),
            action("beginShortcutCapture", "Record shortcut in VoiceInk", [arg("action", "string", true, shortcutOptions)]),
            action("cancelShortcutCapture", "Cancel shortcut recording"),
            action("downloadModel", "Download transcription model", [arg("id", "string")]),
            action("deleteModel", "Delete transcription model", [arg("id", "string")]),
            action("downloadRefinementModel", "Download VoiceInk Refine", [arg("id", "string")]),
            action("cancelRefinementModelDownload", "Cancel VoiceInk Refine download", [arg("id", "string")]),
            action("deleteRefinementModel", "Delete VoiceInk Refine", [arg("id", "string")]),
            action("deleteHistory", "Delete history", [arg("ids", "array")]),
            action("cleanupHistory", "Clean up history", [arg("kind", "string", true, ["transcriptions", "audio"])]),
            action("addPrioritizedAudioDevice", "Add prioritized microphone", [arg("uid", "string")]),
            action("removePrioritizedAudioDevice", "Remove prioritized microphone", [arg("uid", "string")]),
            action("reorderPrioritizedAudioDevices", "Reorder prioritized microphones", [arg("uids", "array")]),
            action("setStartSound", "Set recording start sound", [arg("selection", "string", true, ["none", "builtIn", "custom"]), arg("builtInID", "string", false, CustomSoundManager.BuiltInSound.allCases.map(\.rawValue)), arg("inboxName", "file", false)]),
            action("setStopSound", "Set recording stop sound", [arg("selection", "string", true, ["none", "builtIn", "custom"]), arg("builtInID", "string", false, CustomSoundManager.BuiltInSound.allCases.map(\.rawValue)), arg("inboxName", "file", false)]),
            action("testStartSound", "Play recording start sound"),
            action("testStopSound", "Play recording stop sound"),
            action("upsertMode", "Create or replace mode", [arg("mode", "object")]),
            action("reorderModes", "Reorder modes", [arg("ids", "array")]),
            action("setWhisperPrompt", "Set Whisper prompt", [arg("language", "string"), arg("text", "string")]),
            action("upsertCustomTranscriptionProvider", "Create or update custom transcription provider", [arg("provider", "object")]),
            action("deleteCustomTranscriptionProvider", "Delete custom transcription provider", [arg("id", "string")]),
            action("upsertCustomEnhancementProvider", "Create or update custom enhancement provider", [arg("provider", "object")]),
            action("deleteCustomEnhancementProvider", "Delete custom enhancement provider", [arg("id", "string")]),
            action("setProviderAPIKey", "Store provider API key", [arg("providerID", "string"), arg("apiKey", "string")]),
            action("clearProviderAPIKey", "Remove provider API key", [arg("providerID", "string")]),
            action("verifyProvider", "Verify provider connection", [arg("providerID", "string")]),
            action("refreshProviderModels", "Refresh provider models", [arg("providerID", "string")]),
            action("enqueueAudioImport", "Add audio file to queue", [arg("inboxName", "file"), arg("modeID", "string", false)]),
            action("startAudioImport", "Start queued audio transcription", [arg("id", "string", false), arg("modeID", "string", false)]),
            action("removeAudioImport", "Remove queued audio file", [arg("id", "string")]),
            action("cancelAudioTranscription", "Cancel audio transcription"),
            action("retryAudioTranscription", "Retry audio transcription", [arg("id", "string")]),
            action("clearAudioTranscriptionQueue", "Clear audio transcription queue"),
            action("exportBackup", "Export backup", [arg("categories", "array")]),
            action("importBackup", "Import backup", [arg("inboxName", "file"), arg("categories", "array")]),
            action("exportDiagnostics", "Export diagnostics"),
        ]
    }

    private func selectModel(_ id: String) throws -> CompanionModelSelectionResponse {
        guard let model = transcriptionModelManager.allAvailableModels.first(where: { modelID($0) == id }) else {
            throw CompanionRouteError(404, "model_not_found", "Unknown transcription model")
        }
        guard transcriptionModelManager.usableModels.contains(where: { modelID($0) == modelID(model) }) else {
            throw CompanionRouteError(409, "model_unavailable", "The model is not currently usable")
        }
        if selectionIsBusy {
            pendingModelID = id
            lastModelSelectionError = nil
            return CompanionModelSelectionResponse(status: "pending", id: id)
        }
        try applyModel(id)
        lastModelSelectionError = nil
        return CompanionModelSelectionResponse(status: "applied", id: id)
    }

    private var selectionIsBusy: Bool {
        engine.recordingState != .idle || AudioTranscriptionManager.shared.isProcessingQueue
    }

    private func applyPendingSelectionsIfPossible() {
        guard !selectionIsBusy else { return }

        if let id = pendingModelID {
            do {
                try applyModel(id)
                pendingModelID = nil
                lastModelSelectionError = nil
            } catch {
                pendingModelID = nil
                lastModelSelectionError = "The pending transcription model could not be applied"
            }
        }

        guard let selection = enhancementSelectionQueue.takeIfIdle(true) else { return }
        do {
            try applyEnhancementSelection(selection)
            lastEnhancementSelectionError = nil
        } catch {
            lastEnhancementSelectionError = "The pending enhancement selection could not be applied"
        }
    }

    private func applyModel(_ id: String) throws {
        guard let model = transcriptionModelManager.allAvailableModels.first(where: { modelID($0) == id }) else {
            throw CompanionRouteError(404, "model_not_found", "Unknown transcription model")
        }
        guard transcriptionModelManager.usableModels.contains(where: { modelID($0) == id }) else {
            throw CompanionRouteError(409, "model_unavailable", "The model is not currently usable")
        }
        transcriptionModelManager.setDefaultTranscriptionModel(model)
    }

    private func selectionProgress() -> CompanionStateProgress {
        if pendingModelID != nil {
            return CompanionStateProgress(kind: "modelSelection", status: "pending", message: nil)
        }
        if enhancementSelectionQueue.pending != nil {
            return CompanionStateProgress(kind: "enhancementSelection", status: "pending", message: nil)
        }
        if let message = lastModelSelectionError {
            return CompanionStateProgress(kind: "modelSelection", status: "failed", message: message)
        }
        if let message = lastEnhancementSelectionError {
            return CompanionStateProgress(kind: "enhancementSelection", status: "failed", message: message)
        }
        return CompanionStateProgress(kind: nil, status: "idle", message: nil)
    }

    private func validatedEnhancementProviderSelection(
        _ rawProvider: String
    ) throws -> CompanionPendingEnhancementSelection {
        guard let provider = AIProvider(rawValue: rawProvider), provider.supportsEnhancement else {
            throw CompanionRouteError(400, "invalid_action_args", "Unknown enhancement provider")
        }
        if provider == .voiceInkRefine, !aiService.voiceInkRefineService.isAvailableInModes {
            throw CompanionRouteError(409, "refinement_model_unavailable", "VoiceInk Refine must be downloaded before selection")
        }
        return CompanionPendingEnhancementSelection(
            action: "provider",
            provider: provider.rawValue,
            model: nil
        )
    }

    private func validatedEnhancementModelSelection(
        provider rawProvider: String,
        model: String
    ) throws -> CompanionPendingEnhancementSelection {
        guard let provider = AIProvider(rawValue: rawProvider), provider.supportsEnhancement,
            aiService.availableModels(for: provider).contains(model)
                || (provider == .localCLI && model == provider.defaultModel)
        else {
            throw CompanionRouteError(422, "invalid_action_args", "Enhancement model is unavailable")
        }
        if provider == .voiceInkRefine, !aiService.voiceInkRefineService.isAvailableInModes {
            throw CompanionRouteError(409, "refinement_model_unavailable", "VoiceInk Refine must be downloaded before selection")
        }
        return CompanionPendingEnhancementSelection(
            action: "model",
            provider: provider.rawValue,
            model: model
        )
    }

    private func applyEnhancementSelection(
        _ selection: CompanionPendingEnhancementSelection
    ) throws {
        switch selection.action {
        case "provider":
            let validated = try validatedEnhancementProviderSelection(selection.provider)
            guard let provider = AIProvider(rawValue: validated.provider) else {
                throw CompanionRouteError(400, "invalid_action_args", "Unknown enhancement provider")
            }
            aiService.selectedProvider = provider
        case "model":
            guard let model = selection.model else {
                throw CompanionRouteError(400, "invalid_action_args", "Enhancement model is required")
            }
            let validated = try validatedEnhancementModelSelection(provider: selection.provider, model: model)
            guard let provider = AIProvider(rawValue: validated.provider), let validatedModel = validated.model else {
                throw CompanionRouteError(400, "invalid_action_args", "Enhancement selection is invalid")
            }
            aiService.selectModel(validatedModel, for: provider)
            aiService.selectedProvider = provider
        default:
            throw CompanionRouteError(400, "invalid_action_args", "Unknown enhancement selection")
        }
    }

    private func performAction(_ request: CompanionActionRequest) async throws -> CompanionActionResponse {
        var responseID: String?
        var responseStatus = "applied"
        switch request.action {
        case "checkForUpdates":
            guard updaterViewModel.canCheckForUpdates else {
                throw CompanionRouteError(409, "updater_busy", "Update checking is currently unavailable")
            }
            updaterViewModel.checkForUpdates()
        case "resetOnboarding":
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboardingV2")
        case "openLicenseWindow":
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
            NotificationCenter.default.post(
                name: .navigateToDestination,
                object: nil,
                userInfo: ["destination": ViewType.license.rawValue]
            )
        case "openSection":
            guard case .string(let section)? = request.args?["section"],
                ["Dashboard", "Modes", "AI Models", "Transcribe Audio", "History", "Audio", "Dictionary", "Settings"].contains(section)
            else {
                throw CompanionRouteError(400, "invalid_action_args", "openSection requires a valid section")
            }
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
            NotificationCenter.default.post(
                name: .navigateToDestination,
                object: nil,
                userInfo: ["destination": section]
            )
        case "setActiveMode":
            let rawID = try requiredString(request.args, "id", maximum: 100)
            guard let id = UUID(uuidString: rawID),
                let mode = ModeManager.shared.getConfiguration(with: id), mode.isEnabled
            else {
                throw CompanionRouteError(400, "invalid_action_args", "setActiveMode requires an enabled mode id")
            }
            ModeManager.shared.setActiveConfiguration(mode)
            NotificationCenter.default.post(name: .modeConfigurationApplied, object: nil)
            responseID = id.uuidString
        case "clearActiveMode":
            ModeManager.shared.setActiveConfiguration(nil)
            NotificationCenter.default.post(name: .modeConfigurationApplied, object: nil)
        case "selectEnhancementProvider":
            let rawProvider = try requiredString(request.args, "provider", maximum: 100)
            let selection = try validatedEnhancementProviderSelection(rawProvider)
            if selectionIsBusy {
                enhancementSelectionQueue.enqueue(selection)
                lastEnhancementSelectionError = nil
                responseStatus = "pending"
            } else {
                enhancementSelectionQueue.enqueue(selection)
                guard let immediateSelection = enhancementSelectionQueue.takeIfIdle(true) else {
                    throw CompanionRouteError(500, "selection_failed", "Enhancement selection could not be applied")
                }
                try applyEnhancementSelection(immediateSelection)
                lastEnhancementSelectionError = nil
            }
            responseID = selection.provider
        case "selectEnhancementModel":
            let rawProvider = try requiredString(request.args, "provider", maximum: 100)
            let model = try requiredString(request.args, "model", maximum: 500)
            let selection = try validatedEnhancementModelSelection(provider: rawProvider, model: model)
            if selectionIsBusy {
                enhancementSelectionQueue.enqueue(selection)
                lastEnhancementSelectionError = nil
                responseStatus = "pending"
            } else {
                enhancementSelectionQueue.enqueue(selection)
                guard let immediateSelection = enhancementSelectionQueue.takeIfIdle(true) else {
                    throw CompanionRouteError(500, "selection_failed", "Enhancement selection could not be applied")
                }
                try applyEnhancementSelection(immediateSelection)
                lastEnhancementSelectionError = nil
            }
            responseID = model
        case "upsertPrompt":
            let title = try requiredString(request.args, "title", maximum: 200)
            let promptText = try requiredString(request.args, "promptText", maximum: 20_000, allowEmpty: true)
            let useSystemInstructions = try requiredBool(request.args, "useSystemInstructions")
            if let rawID = try optionalString(request.args, "id", maximum: 100), !rawID.isEmpty {
                guard let id = UUID(uuidString: rawID),
                    enhancementService.allPrompts.contains(where: { $0.id == id })
                else { throw CompanionRouteError(404, "prompt_not_found", "Unknown prompt") }
                enhancementService.updatePrompt(
                    CustomPrompt(id: id, title: title, promptText: promptText, useSystemInstructions: useSystemInstructions)
                )
                responseID = id.uuidString
            } else {
                responseID = enhancementService.addPrompt(
                    title: title,
                    promptText: promptText,
                    useSystemInstructions: useSystemInstructions
                ).id.uuidString
            }
        case "deletePrompt":
            let rawID = try requiredString(request.args, "id", maximum: 100)
            guard let id = UUID(uuidString: rawID),
                let prompt = enhancementService.allPrompts.first(where: { $0.id == id })
            else { throw CompanionRouteError(404, "prompt_not_found", "Unknown prompt") }
            enhancementService.deletePrompt(prompt)
            responseID = id.uuidString
        case "createMode":
            let name = try requiredString(request.args, "name", maximum: 200)
            let mode = ModeConfig(name: name, isAIEnhancementEnabled: false)
            ModeManager.shared.addConfiguration(mode)
            responseID = mode.id.uuidString
        case "updateMode":
            let id = try requiredUUID(request.args, "id")
            guard var mode = ModeManager.shared.getConfiguration(with: id) else {
                throw CompanionRouteError(404, "mode_not_found", "Unknown mode")
            }
            if let value = try optionalString(request.args, "name", maximum: 200) { mode.name = value }
            if let value = optionalBool(request.args, "isAIEnhancementEnabled") { mode.isAIEnhancementEnabled = value }
            if request.args?["promptID"] != nil {
                let value = try optionalString(request.args, "promptID", maximum: 100)
                if let value, !enhancementService.allPrompts.contains(where: { $0.id.uuidString == value }) {
                    throw CompanionRouteError(422, "invalid_action_args", "Unknown prompt id")
                }
                mode.selectedPrompt = value
            }
            if let value = try optionalString(request.args, "transcriptionModelName", maximum: 500) {
                guard transcriptionModelManager.allAvailableModels.contains(where: { $0.name == value }) else {
                    throw CompanionRouteError(422, "invalid_action_args", "Unknown transcription model")
                }
                mode.selectedTranscriptionModelName = value
            }
            if let value = try optionalString(request.args, "language", maximum: 50) { mode.selectedLanguage = value }
            if let value = optionalBool(request.args, "isTextFormattingEnabled") { mode.isTextFormattingEnabled = value }
            if let value = try optionalString(request.args, "enhancementProvider", maximum: 100) {
                guard AIProvider(rawValue: value)?.supportsEnhancement == true else {
                    throw CompanionRouteError(422, "invalid_action_args", "Unknown enhancement provider")
                }
                mode.selectedAIProvider = value
            }
            if let value = try optionalString(request.args, "enhancementModel", maximum: 500) { mode.selectedAIModel = value }
            if let value = try optionalString(request.args, "outputMode", maximum: 50) {
                guard let output = ModeOutputMode(rawValue: value) else {
                    throw CompanionRouteError(422, "invalid_action_args", "Unknown output mode")
                }
                mode.outputMode = output
            }
            if let value = try optionalString(request.args, "autoSendKey", maximum: 50) {
                guard let autoSend = AutoSendKey(rawValue: value) else {
                    throw CompanionRouteError(422, "invalid_action_args", "Unknown auto-send key")
                }
                mode.autoSendKey = autoSend
            }
            if let value = optionalBool(request.args, "isEnabled") { mode.isEnabled = value }
            if let value = optionalBool(request.args, "isDefault") { mode.isDefault = value }
            ModeManager.shared.updateConfiguration(mode)
            responseID = id.uuidString
        case "deleteMode":
            let id = try requiredUUID(request.args, "id")
            switch ModeManager.shared.removeConfiguration(with: id) {
            case .removed: break
            case .blockedDefault: throw CompanionRouteError(409, "default_mode", "The default mode cannot be deleted")
            case .notFound: throw CompanionRouteError(404, "mode_not_found", "Unknown mode")
            }
            responseID = id.uuidString
        case "setModeEnabled":
            let id = try requiredUUID(request.args, "id")
            let enabled = try requiredBool(request.args, "enabled")
            guard let mode = ModeManager.shared.getConfiguration(with: id) else {
                throw CompanionRouteError(404, "mode_not_found", "Unknown mode")
            }
            if !enabled && mode.isDefault {
                throw CompanionRouteError(409, "default_mode", "The default mode cannot be disabled")
            }
            enabled ? ModeManager.shared.enableConfiguration(with: id) : ModeManager.shared.disableConfiguration(with: id)
            responseID = id.uuidString
        case "setDefaultMode":
            let id = try requiredUUID(request.args, "id")
            guard ModeManager.shared.getConfiguration(with: id) != nil else {
                throw CompanionRouteError(404, "mode_not_found", "Unknown mode")
            }
            ModeManager.shared.setAsDefault(configId: id)
            responseID = id.uuidString
        case "selectAudioInputMode":
            guard engine.recordingState == .idle else {
                throw CompanionRouteError(409, "engine_busy", "Audio input cannot change while VoiceInk is busy")
            }
            let rawMode = try requiredString(request.args, "mode", maximum: 100)
            guard let mode = AudioInputMode(rawValue: rawMode) else {
                throw CompanionRouteError(422, "invalid_action_args", "Unknown audio input mode")
            }
            AudioDeviceManager.shared.selectInputMode(mode)
            responseID = mode.rawValue
        case "selectMicrophone":
            guard engine.recordingState == .idle else {
                throw CompanionRouteError(409, "engine_busy", "Microphone cannot change while VoiceInk is busy")
            }
            let uid = try requiredString(request.args, "uid", maximum: 1_000)
            guard let device = AudioDeviceManager.shared.availableDevices.first(where: { $0.uid == uid }) else {
                throw CompanionRouteError(404, "microphone_not_found", "Unknown microphone")
            }
            AudioDeviceManager.shared.selectDeviceAndSwitchToCustomMode(id: device.id)
            responseID = uid
        case "setShortcut":
            let actionID = try requiredString(request.args, "action", maximum: 200)
            guard let action = shortcutActions().first(where: { $0.0 == actionID })?.2 else {
                throw CompanionRouteError(404, "shortcut_action_not_found", "Unknown shortcut action")
            }
            let kindRaw = try requiredString(request.args, "kind", maximum: 50)
            guard let kind = Shortcut.Kind(rawValue: kindRaw) else {
                throw CompanionRouteError(422, "invalid_action_args", "Unknown shortcut kind")
            }
            let keyCode = try requiredUInt16(request.args, "keyCode")
            let modifiers = try requiredUInt(request.args, "modifiers")
            let shortcut = Shortcut(kind: kind, keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers))
            if let validation = ShortcutValidator.validationError(for: shortcut, action: action) {
                throw CompanionRouteError(422, "invalid_shortcut", validation.notificationTitle(for: shortcut))
            }
            ShortcutStore.setShortcut(shortcut, for: action)
            responseID = actionID
        case "clearShortcut":
            let actionID = try requiredString(request.args, "action", maximum: 200)
            guard let action = shortcutActions().first(where: { $0.0 == actionID })?.2 else {
                throw CompanionRouteError(404, "shortcut_action_not_found", "Unknown shortcut action")
            }
            ShortcutStore.setShortcut(nil, for: action)
            responseID = actionID
        case "beginShortcutCapture":
            guard engine.recordingState == .idle, !AudioTranscriptionManager.shared.isProcessingQueue else {
                throw CompanionRouteError(409, "engine_busy", "Shortcut recording requires VoiceInk to be idle")
            }
            guard shortcutCaptureAction == nil else {
                throw CompanionRouteError(409, "shortcut_capture_busy", "A shortcut recording is already active")
            }
            let actionID = try requiredString(request.args, "action", maximum: 200)
            guard let action = shortcutActions().first(where: { $0.0 == actionID })?.2 else {
                throw CompanionRouteError(404, "shortcut_action_not_found", "Unknown shortcut action")
            }
            beginShortcutCapture(actionID: actionID, action: action)
            responseID = actionID
            responseStatus = "pending"
        case "cancelShortcutCapture":
            guard shortcutCaptureAction != nil else {
                throw CompanionRouteError(409, "shortcut_capture_idle", "No shortcut recording is active")
            }
            finishShortcutCapture(status: "cancelled", display: nil, restoreOriginal: true)
        case "downloadModel":
            let id = try requiredString(request.args, "id", maximum: 200)
            try startModelDownload(id)
            responseID = id
            responseStatus = "pending"
        case "deleteModel":
            let id = try requiredString(request.args, "id", maximum: 200)
            if try deleteModel(id) { responseStatus = "pending" }
            responseID = id
        case "downloadRefinementModel":
            let id = try requiredRefinementModelID(request.args)
            let service = aiService.voiceInkRefineService
            guard service.availability == .available else {
                throw CompanionRouteError(409, "refinement_model_unavailable", "VoiceInk Refine is unavailable on this Mac")
            }
            guard !service.isDownloaded else {
                throw CompanionRouteError(409, "model_installed", "VoiceInk Refine is already downloaded")
            }
            guard !service.isDownloading else {
                throw CompanionRouteError(409, "model_download_busy", "VoiceInk Refine is already downloading")
            }
            try rejectSharedModelMutationInCompanionTest()
            service.startDownload()
            responseID = id
            responseStatus = "pending"
        case "cancelRefinementModelDownload":
            let id = try requiredRefinementModelID(request.args)
            let service = aiService.voiceInkRefineService
            guard service.isDownloading else {
                throw CompanionRouteError(409, "model_download_idle", "VoiceInk Refine is not downloading")
            }
            service.cancelDownload()
            responseID = id
            responseStatus = "pending"
        case "deleteRefinementModel":
            let id = try requiredRefinementModelID(request.args)
            let service = aiService.voiceInkRefineService
            guard service.isDownloaded else {
                throw CompanionRouteError(409, "model_not_deletable", "VoiceInk Refine is not downloaded")
            }
            try rejectSharedModelMutationInCompanionTest()
            await service.deleteModel()
            guard !service.isDownloaded else {
                throw CompanionRouteError(500, "model_delete_failed", "VoiceInk Refine could not be deleted")
            }
            responseID = id
        case "deleteHistory":
            let ids = try requiredUUIDArray(request.args, "ids", maximumCount: 500)
            let all = try modelContext.fetch(FetchDescriptor<Transcription>())
            let selected = all.filter { ids.contains($0.id) }
            guard selected.count == ids.count else {
                throw CompanionRouteError(404, "history_not_found", "One or more history items no longer exist")
            }
            _ = await AudioCleanupManager.shared.runCleanupForTranscriptions(
                modelContext: modelContext, transcriptions: selected)
            selected.forEach(modelContext.delete)
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
        case "cleanupHistory":
            let kind = try requiredString(request.args, "kind", maximum: 30)
            if kind == "transcriptions" {
                await TranscriptionAutoCleanupService.shared.runManualCleanup(modelContext: modelContext)
            } else if kind == "audio" {
                await AudioCleanupManager.shared.runManualCleanup(modelContext: modelContext)
            } else {
                throw CompanionRouteError(422, "invalid_action_args", "Unknown cleanup kind")
            }
        case "addPrioritizedAudioDevice":
            let uid = try requiredString(request.args, "uid", maximum: 1_000)
            guard let device = AudioDeviceManager.shared.availableDevices.first(where: { $0.uid == uid }) else {
                throw CompanionRouteError(404, "microphone_not_found", "Unknown microphone")
            }
            AudioDeviceManager.shared.addPrioritizedDevice(uid: uid, name: device.name)
            responseID = uid
        case "removePrioritizedAudioDevice":
            let uid = try requiredString(request.args, "uid", maximum: 1_000)
            guard AudioDeviceManager.shared.prioritizedDevices.contains(where: { $0.id == uid }) else {
                throw CompanionRouteError(404, "microphone_not_found", "Microphone is not prioritized")
            }
            AudioDeviceManager.shared.removePrioritizedDevice(id: uid)
            responseID = uid
        case "reorderPrioritizedAudioDevices":
            let uids = try requiredStringArray(request.args, "uids", maximumCount: 100, maximumLength: 1_000)
            let existing = AudioDeviceManager.shared.prioritizedDevices
            guard Set(uids).count == uids.count, Set(uids) == Set(existing.map(\.id)) else {
                throw CompanionRouteError(409, "priority_conflict", "Prioritized microphone IDs must match current state")
            }
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let reordered = uids.enumerated().compactMap { index, id -> PrioritizedDevice? in
                guard let item = byID[id] else { return nil }
                return PrioritizedDevice(id: item.id, name: item.name, priority: index, modelUID: item.modelUID)
            }
            AudioDeviceManager.shared.updatePriorities(devices: reordered)
        case "setStartSound", "setStopSound":
            let type: CustomSoundManager.SoundType = request.action == "setStartSound" ? .start : .stop
            let selection = try requiredString(request.args, "selection", maximum: 30)
            switch selection {
            case "none":
                CustomSoundManager.shared.selectNoSound(for: type)
            case "builtIn":
                let raw = try requiredString(request.args, "builtInID", maximum: 30)
                guard let sound = CustomSoundManager.BuiltInSound(rawValue: raw) else {
                    throw CompanionRouteError(422, "invalid_action_args", "Unknown built-in sound")
                }
                CustomSoundManager.shared.selectBuiltInSound(sound, for: type)
            case "custom":
                let inboxName = try requiredString(request.args, "inboxName", maximum: 255)
                let url = try inboxURL(named: inboxName, maximumBytes: 20 * 1_024 * 1_024)
                switch await CustomSoundManager.shared.setCustomSound(url: url, for: type) {
                case .success: break
                case .failure:
                    throw CompanionRouteError(422, "invalid_sound", "The staged file is not a valid recording sound")
                }
            default:
                throw CompanionRouteError(422, "invalid_action_args", "Unknown sound selection")
            }
        case "testStartSound":
            SoundManager.shared.playStartSound()
        case "testStopSound":
            SoundManager.shared.playStopSound()
        case "upsertMode":
            let mode = try requiredDecodableArgument(ModeConfig.self, request.args, "mode")
            guard !mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                mode.name.count <= 200,
                mode.triggerWords.count <= 200,
                mode.triggerWords.allSatisfy({ $0.count <= 200 })
            else {
                throw CompanionRouteError(422, "invalid_mode", "Mode fields exceed their allowed limits")
            }
            if ModeManager.shared.getConfiguration(with: mode.id) == nil {
                ModeManager.shared.addConfiguration(mode)
            } else {
                ModeManager.shared.updateConfiguration(mode)
            }
            responseID = mode.id.uuidString
        case "reorderModes":
            let ids = try requiredUUIDArray(request.args, "ids", maximumCount: 200)
            let current = ModeManager.shared.configurations
            guard ids.count == current.count, Set(ids) == Set(current.map(\.id)) else {
                throw CompanionRouteError(409, "mode_order_conflict", "Mode IDs must match current state")
            }
            let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            ModeManager.shared.replaceConfigurations(ids.compactMap { byID[$0] })
        case "setWhisperPrompt":
            let language = try requiredString(request.args, "language", maximum: 50)
            let text = try requiredString(request.args, "text", maximum: 10_000, allowEmpty: true)
            whisperModelManager.whisperPrompt.setCustomPrompt(text, for: language)
            responseID = language
        case "upsertCustomTranscriptionProvider":
            let model = try requiredDecodableArgument(CustomCloudModel.self, request.args, "provider")
            let manager = CustomCloudModelManager.shared
            let errors = manager.validateModelDetails(
                name: model.name,
                displayName: model.displayName,
                apiEndpoint: model.apiEndpoint,
                modelName: model.modelName,
                excludingId: model.id
            )
            guard errors.isEmpty else {
                throw CompanionRouteError(422, "invalid_provider", String(errors.joined(separator: "; ").prefix(500)))
            }
            if manager.customModels.contains(where: { $0.id == model.id }) {
                guard manager.updateCustomModel(model) else {
                    throw CompanionRouteError(500, "provider_save_failed", "Custom provider could not be updated")
                }
            } else {
                manager.customModels.append(model)
                manager.saveCustomModels()
            }
            transcriptionModelManager.refreshAllAvailableModels()
            responseID = "transcription:\(model.id.uuidString)"
        case "deleteCustomTranscriptionProvider":
            let id = try providerUUID(request.args, expectedPrefix: "transcription")
            guard CustomCloudModelManager.shared.customModels.contains(where: { $0.id == id }) else {
                throw CompanionRouteError(404, "provider_not_found", "Unknown custom transcription provider")
            }
            CustomCloudModelManager.shared.removeCustomModel(withId: id)
            transcriptionModelManager.refreshAllAvailableModels()
            responseID = "transcription:\(id.uuidString)"
        case "upsertCustomEnhancementProvider":
            let provider = try requiredDecodableArgument(CustomAIProviderConfig.self, request.args, "provider")
            let manager = CustomAIProviderManager.shared
            let errors = manager.validateProvider(
                name: provider.name,
                baseURL: provider.baseURL,
                model: provider.modelName,
                excluding: provider.id
            )
            guard errors.isEmpty else {
                throw CompanionRouteError(422, "invalid_provider", String(errors.joined(separator: "; ").prefix(500)))
            }
            if manager.providers.contains(where: { $0.id == provider.id }) {
                guard manager.updateProvider(provider) else {
                    throw CompanionRouteError(500, "provider_save_failed", "Custom provider could not be updated")
                }
            } else {
                guard let key = APIKeyManager.shared.getCustomAIProviderAPIKey(forProviderId: provider.id),
                    manager.addProvider(provider, apiKey: key)
                else {
                    throw CompanionRouteError(
                        409, "provider_key_required",
                        "Store the API key for this provider ID before creating the provider")
                }
            }
            responseID = "enhancement:\(provider.id.uuidString)"
        case "deleteCustomEnhancementProvider":
            let id = try providerUUID(request.args, expectedPrefix: "enhancement")
            guard let provider = CustomAIProviderManager.shared.providers.first(where: { $0.id == id }) else {
                throw CompanionRouteError(404, "provider_not_found", "Unknown custom enhancement provider")
            }
            CustomAIProviderManager.shared.deleteProvider(provider)
            responseID = "enhancement:\(id.uuidString)"
        case "setProviderAPIKey":
            let providerID = try requiredString(request.args, "providerID", maximum: 200)
            let apiKey = try requiredString(request.args, "apiKey", maximum: 20_000)
            guard saveProviderAPIKey(apiKey, providerID: providerID) else {
                throw CompanionRouteError(500, "keychain_write_failed", "The API key could not be stored securely")
            }
            providerVerificationStatus[providerID] = "unverified"
            NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
            responseID = providerID
        case "clearProviderAPIKey":
            let providerID = try requiredString(request.args, "providerID", maximum: 200)
            guard deleteProviderAPIKey(providerID: providerID) else {
                throw CompanionRouteError(500, "keychain_delete_failed", "The API key could not be removed")
            }
            providerVerificationStatus[providerID] = "missingKey"
            NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
            responseID = providerID
        case "verifyProvider":
            let providerID = try requiredString(request.args, "providerID", maximum: 200)
            try await verifyProvider(providerID)
            providerVerificationStatus[providerID] = "verified"
            responseID = providerID
        case "refreshProviderModels":
            let providerID = try requiredString(request.args, "providerID", maximum: 200)
            if providerID == AIProvider.openRouter.rawValue {
                await aiService.fetchOpenRouterModels()
            } else if providerID == AIProvider.ollama.rawValue {
                _ = await aiService.refreshOllamaConnectionAndModels()
            } else {
                transcriptionModelManager.refreshAllAvailableModels()
            }
            responseID = providerID
        case "enqueueAudioImport":
            let inboxName = try requiredString(request.args, "inboxName", maximum: 255)
            let url = try inboxURL(named: inboxName, maximumBytes: 5 * 1_024 * 1_024 * 1_024)
            let manager = AudioTranscriptionManager.shared
            let before = Set(manager.queue.map(\.id))
            manager.addToQueue(urls: [url])
            guard let item = manager.queue.first(where: { !before.contains($0.id) }) else {
                throw CompanionRouteError(422, "unsupported_audio", "Audio file is unsupported or already queued")
            }
            responseID = item.id.uuidString
        case "startAudioImport":
            let manager = AudioTranscriptionManager.shared
            if let rawID = try optionalString(request.args, "id", maximum: 100) {
                guard let id = UUID(uuidString: rawID), manager.queue.contains(where: { $0.id == id }) else {
                    throw CompanionRouteError(404, "audio_job_not_found", "Unknown audio transcription job")
                }
                responseID = id.uuidString
            }
            let preferredModeID = try optionalString(request.args, "modeID", maximum: 100).flatMap(UUID.init(uuidString:))
            guard let mode = ModeManager.shared.resolvedEnabledConfiguration(preferredId: preferredModeID) else {
                throw CompanionRouteError(409, "mode_unavailable", "No enabled mode is available")
            }
            guard manager.hasPendingItems else {
                throw CompanionRouteError(409, "queue_empty", "No pending audio import is queued")
            }
            manager.startProcessing(modelContext: modelContext, engine: engine, mode: mode)
            responseStatus = "pending"
        case "removeAudioImport":
            let id = try requiredUUID(request.args, "id")
            let manager = AudioTranscriptionManager.shared
            guard let item = manager.queue.first(where: { $0.id == id }) else {
                throw CompanionRouteError(404, "audio_job_not_found", "Unknown audio transcription job")
            }
            guard case .pending = item.status else {
                throw CompanionRouteError(409, "audio_job_busy", "Only pending audio jobs can be removed")
            }
            manager.removeFromQueue(id: id)
            responseID = id.uuidString
        case "exportBackup":
            let categories = try requiredBackupCategories(request.args)
            let backup = try await backupFile(categories: categories)
            let encoder = JSONEncoder.companion
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(backup)
            guard data.count <= 16 * 1_024 * 1_024 else {
                throw CompanionRouteError(413, "backup_too_large", "Backup exceeds the 16 MiB export limit")
            }
            responseID = storeArtifact(
                data: data, contentType: "application/json", filename: "VoiceInk_Settings_Backup.json")
        case "importBackup":
            let categories = try requiredBackupCategories(request.args)
            let inboxName = try requiredString(request.args, "inboxName", maximum: 255)
            let url = try inboxURL(named: inboxName, maximumBytes: 1_048_576)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let backup = try JSONDecoder.companion.decode(BackupFile.self, from: data)
            try BackupImporter.apply(
                backup,
                categories: categories,
                enhancementService: enhancementService,
                recordingShortcutManager: recordingShortcutManager,
                menuBarManager: menuBarManager,
                mediaController: .shared,
                playbackController: .shared,
                recorderUIManager: recorderUIManager,
                modelContext: modelContext,
                transcriptionModelManager: transcriptionModelManager
            )
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        case "exportDiagnostics":
            let url = try await LogExporter.shared.exportLogs()
            defer { try? FileManager.default.removeItem(at: url) }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= 16 * 1_024 * 1_024 else {
                throw CompanionRouteError(413, "diagnostics_too_large", "Diagnostics exceed the 16 MiB export limit")
            }
            responseID = storeArtifact(
                data: try Data(contentsOf: url, options: [.mappedIfSafe]),
                contentType: "text/plain; charset=utf-8",
                filename: "VoiceInk_Diagnostics.log"
            )
        case "transcribeAudio":
            let path = try requiredString(request.args, "path", maximum: 8_192)
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let inbox = try CompanionEnvironment.importInboxDirectory().standardizedFileURL.resolvingSymlinksInPath()
            let inboxPrefix = inbox.path.hasSuffix("/") ? inbox.path : inbox.path + "/"
            guard path.hasPrefix("/"), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
                let size = attributes[.size] as? NSNumber, size.int64Value <= 5 * 1_024 * 1_024 * 1_024,
                url.path.hasPrefix(inboxPrefix)
            else {
                throw CompanionRouteError(
                    422,
                    "invalid_audio_path",
                    "Audio must be a regular file copied into the Companion Inbox"
                )
            }
            let preferredModeID = try optionalString(request.args, "modeID", maximum: 100).flatMap(UUID.init(uuidString:))
            guard let mode = ModeManager.shared.resolvedEnabledConfiguration(preferredId: preferredModeID) else {
                throw CompanionRouteError(409, "mode_unavailable", "No enabled mode is available")
            }
            let manager = AudioTranscriptionManager.shared
            let before = Set(manager.queue.map(\.id))
            manager.addToQueue(urls: [url])
            guard let item = manager.queue.first(where: { !before.contains($0.id) }) else {
                throw CompanionRouteError(422, "unsupported_audio", "Audio file is unsupported or already queued")
            }
            manager.startProcessing(modelContext: modelContext, engine: engine, mode: mode)
            responseID = item.id.uuidString
            responseStatus = "pending"
        case "cancelAudioTranscription":
            AudioTranscriptionManager.shared.cancelProcessing()
        case "retryAudioTranscription":
            let id = try requiredUUID(request.args, "id")
            let manager = AudioTranscriptionManager.shared
            guard manager.queue.contains(where: { $0.id == id }) else {
                throw CompanionRouteError(404, "audio_job_not_found", "Unknown audio transcription job")
            }
            guard let mode = ModeManager.shared.currentEffectiveConfiguration else {
                throw CompanionRouteError(409, "mode_unavailable", "No enabled mode is available")
            }
            manager.retryItem(id: id)
            manager.startProcessing(modelContext: modelContext, engine: engine, mode: mode)
            responseID = id.uuidString
            responseStatus = "pending"
        case "clearAudioTranscriptionQueue":
            AudioTranscriptionManager.shared.clearAll()
        default:
            throw CompanionRouteError(400, "unknown_action", "Action is not supported")
        }
        return CompanionActionResponse(status: responseStatus, action: request.action, id: responseID)
    }

    private func beginShortcutCapture(actionID: String, action: ShortcutAction) {
        let expiresAt = Date().addingTimeInterval(20)
        shortcutCaptureAction = action
        shortcutCaptureOriginal = ShortcutStore.shortcut(for: action)
        shortcutCapture = CompanionShortcutCaptureState(
            status: "capturing", action: actionID, display: nil, expiresAt: expiresAt)

        // Match the native ShortcutRecorder flow: remove the active binding while recording so
        // the requested shortcut cannot trigger dictation before validation completes.
        ShortcutStore.setShortcut(nil, for: action)
        NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        NotificationCenter.default.post(
            name: .navigateToDestination,
            object: nil,
            userInfo: ["destination": ViewType.settings.rawValue]
        )
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        shortcutRecorder.start(action: action) { [weak self] shortcut in
            self?.finishShortcutCapture(
                status: "captured", display: shortcut.displayString, restoreOriginal: false)
        }
        shortcutCaptureTimeout?.cancel()
        shortcutCaptureTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, self?.shortcutCaptureAction != nil else { return }
            self?.finishShortcutCapture(status: "timedOut", display: nil, restoreOriginal: true)
        }
    }

    private func finishShortcutCapture(status: String, display: String?, restoreOriginal: Bool) {
        let actionID = shortcutCapture.action
        let action = shortcutCaptureAction
        let original = shortcutCaptureOriginal
        shortcutCaptureTimeout?.cancel()
        shortcutCaptureTimeout = nil
        shortcutRecorder.cancel()
        if restoreOriginal, let action, ShortcutStore.shortcut(for: action) == nil, let original {
            ShortcutStore.setShortcut(original, for: action)
        }
        shortcutCaptureAction = nil
        shortcutCaptureOriginal = nil
        shortcutCapture = CompanionShortcutCaptureState(
            status: status, action: actionID, display: display, expiresAt: nil)
    }

    private func reviewSuggestions(_ request: CompanionReviewRequest) async throws -> CompanionReviewResponse {
        let original = try validatedText(request.original, field: "original", maximum: 20_000, allowEmpty: true)
        let corrected = try validatedText(request.corrected, field: "corrected", maximum: 20_000, allowEmpty: true)
        guard original != corrected else { return CompanionReviewResponse(suggestions: []) }

        let provider = aiService.selectedProvider
        guard provider != .localCLI else {
            throw CompanionRouteError(503, "provider_unavailable", "Local CLI review is disabled because provider stderr may expose review text")
        }
        guard aiService.connectedProviders.contains(provider) else {
            throw CompanionRouteError(503, "provider_unavailable", "The selected enhancement provider is unavailable")
        }
        let prompt = CustomPrompt(
            title: "Companion Review",
            promptText: """
                Compare the original transcript with the user's corrected transcript. Return only JSON with this shape:
                {"suggestions":[{"original":"exact original fragment","corrected":"exact corrected fragment","reason":"brief reason"}]}
                Include only reusable spelling, vocabulary, or replacement corrections. Do not include commentary or Markdown.
                """,
            useSystemInstructions: false
        )
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: true,
            prompt: provider == .voiceInkRefine ? nil : prompt,
            provider: provider,
            modelName: aiService.currentModel,
            useClipboardContext: false,
            useSelectedTextContext: false,
            useScreenCaptureContext: false
        )
        let comparison = try JSONEncoder.companion.encode(CompanionReviewComparison(original: original, corrected: corrected))
        guard let comparisonText = String(data: comparison, encoding: .utf8) else {
            throw CompanionRouteError(500, "review_encoding_failed", "Review input could not be encoded")
        }
        let result = try await enhancementService.enhance(comparisonText, configuration: configuration)
        let parsed = parseSuggestions(result.text).filter {
            !$0.original.isEmpty && !$0.corrected.isEmpty && $0.original != $0.corrected
                && $0.original.count <= 2_000 && $0.corrected.count <= 2_000 && $0.reason.count <= 2_000
        }
        guard !parsed.isEmpty else {
            throw CompanionRouteError(502, "invalid_provider_response", "The selected provider returned no structured suggestions")
        }
        return CompanionReviewResponse(suggestions: parsed)
    }

    private func startModelDownload(_ id: String) throws {
        guard let model = transcriptionModelManager.allAvailableModels.first(where: { modelID($0) == id }) else {
            throw CompanionRouteError(404, "model_not_found", "Unknown transcription model")
        }
        guard !transcriptionModelManager.usableModels.contains(where: { modelID($0) == id }) else {
            throw CompanionRouteError(409, "model_installed", "The model is already installed or usable")
        }
        if let whisper = model as? WhisperModel {
            Task { @MainActor [whisperModelManager] in await whisperModelManager.downloadModel(whisper) }
        } else if let fluid = model as? FluidAudioModel {
            try rejectSharedModelMutationInCompanionTest()
            Task { @MainActor [fluidAudioModelManager] in await fluidAudioModelManager.downloadFluidAudioModel(fluid) }
        } else if let transcribe = model as? TranscribeCppModel {
            try rejectSharedModelMutationInCompanionTest()
            Task { @MainActor in await TranscribeCppModelManager.shared.downloadModel(transcribe) }
        } else {
            throw CompanionRouteError(409, "model_not_downloadable", "This model is managed by its provider")
        }
    }

    private func deleteModel(_ id: String) throws -> Bool {
        guard let model = transcriptionModelManager.allAvailableModels.first(where: { modelID($0) == id }) else {
            throw CompanionRouteError(404, "model_not_found", "Unknown transcription model")
        }
        if modelID(model) == transcriptionModelManager.currentTranscriptionModel.map(modelID) {
            throw CompanionRouteError(409, "model_selected", "Select another transcription model before deleting this one")
        }
        if let whisper = model as? WhisperModel,
            let file = whisperModelManager.availableModels.first(where: { $0.name == whisper.name })
        {
            Task { @MainActor [whisperModelManager] in await whisperModelManager.deleteModel(file) }
            return true
        }
        if let fluid = model as? FluidAudioModel, fluidAudioModelManager.isFluidAudioModelDownloaded(fluid) {
            try rejectSharedModelMutationInCompanionTest()
            fluidAudioModelManager.deleteFluidAudioModel(fluid)
            return false
        }
        if let transcribe = model as? TranscribeCppModel,
            TranscribeCppModelManager.shared.isModelDownloaded(transcribe)
        {
            try rejectSharedModelMutationInCompanionTest()
            TranscribeCppModelManager.shared.deleteModel(transcribe)
            return false
        }
        throw CompanionRouteError(409, "model_not_deletable", "This model is not an installed local model")
    }

    private func rejectSharedModelMutationInCompanionTest() throws {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".CompanionTest") != true else {
            throw CompanionRouteError(
                409,
                "shared_model_store",
                "This provider uses a shared model store and cannot be mutated from CompanionTest"
            )
        }
    }

    private func requiredRefinementModelID(
        _ args: [String: CompanionJSONValue]?
    ) throws -> String {
        let id = try requiredString(args, "id", maximum: 200)
        guard id == refinementModelID else {
            throw CompanionRouteError(404, "model_not_found", "Unknown refinement model")
        }
        return id
    }

    private func requiredString(
        _ args: [String: CompanionJSONValue]?,
        _ key: String,
        maximum: Int,
        allowEmpty: Bool = false
    ) throws -> String {
        guard case .string(let value)? = args?[key], value.count <= maximum,
            allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CompanionRouteError(400, "invalid_action_args", "\(key) requires a string within limits") }
        return value
    }

    private func optionalString(
        _ args: [String: CompanionJSONValue]?,
        _ key: String,
        maximum: Int
    ) throws -> String? {
        guard let value = args?[key] else { return nil }
        if case .null = value { return nil }
        guard case .string(let string) = value, string.count <= maximum else {
            throw CompanionRouteError(400, "invalid_action_args", "\(key) requires a string within limits")
        }
        return string
    }

    private func requiredBool(_ args: [String: CompanionJSONValue]?, _ key: String) throws -> Bool {
        guard case .bool(let value)? = args?[key] else {
            throw CompanionRouteError(400, "invalid_action_args", "\(key) requires a boolean")
        }
        return value
    }

    private func optionalBool(_ args: [String: CompanionJSONValue]?, _ key: String) -> Bool? {
        guard case .bool(let value)? = args?[key] else { return nil }
        return value
    }

    private func requiredUUID(_ args: [String: CompanionJSONValue]?, _ key: String) throws -> UUID {
        let raw = try requiredString(args, key, maximum: 100)
        guard let value = UUID(uuidString: raw) else {
            throw CompanionRouteError(400, "invalid_action_args", "\(key) requires a UUID")
        }
        return value
    }

    private func requiredStringArray(
        _ args: [String: CompanionJSONValue]?,
        _ key: String,
        maximumCount: Int,
        maximumLength: Int
    ) throws -> [String] {
        guard case .array(let values)? = args?[key], !values.isEmpty, values.count <= maximumCount else {
            throw CompanionRouteError(400, "invalid_action_args", "\(key) requires a bounded non-empty array")
        }
        let strings = try values.map { value -> String in
            guard case .string(let string) = value, !string.isEmpty, string.count <= maximumLength else {
                throw CompanionRouteError(422, "invalid_action_args", "\(key) contains an invalid string")
            }
            return string
        }
        guard Set(strings).count == strings.count else {
            throw CompanionRouteError(422, "invalid_action_args", "\(key) contains duplicate values")
        }
        return strings
    }

    private func requiredUUIDArray(
        _ args: [String: CompanionJSONValue]?,
        _ key: String,
        maximumCount: Int
    ) throws -> [UUID] {
        try requiredStringArray(args, key, maximumCount: maximumCount, maximumLength: 100).map {
            guard let id = UUID(uuidString: $0) else {
                throw CompanionRouteError(422, "invalid_action_args", "\(key) contains an invalid UUID")
            }
            return id
        }
    }

    private func requiredDecodableArgument<T: Decodable>(
        _ type: T.Type,
        _ args: [String: CompanionJSONValue]?,
        _ key: String
    ) throws -> T {
        guard let value = args?[key] else {
            throw CompanionRouteError(400, "invalid_action_args", "Missing \(key)")
        }
        let data = try JSONEncoder.companion.encode(value)
        do {
            return try JSONDecoder.companion.decode(type, from: data)
        } catch {
            throw CompanionRouteError(422, "invalid_action_args", "\(key) does not match the native schema")
        }
    }

    private func inboxURL(named name: String, maximumBytes: Int64) throws -> URL {
        guard !name.isEmpty, name.count <= 255, !name.contains("/"), !name.contains("\\"),
            name != ".", name != ".."
        else {
            throw CompanionRouteError(422, "invalid_inbox_file", "Inbox file name is invalid")
        }
        let inbox = try CompanionEnvironment.importInboxDirectory().standardizedFileURL.resolvingSymlinksInPath()
        let url = inbox.appendingPathComponent(name, isDirectory: false).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = inbox.path.hasSuffix("/") ? inbox.path : inbox.path + "/"
        guard url.path.hasPrefix(prefix),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.int64Value <= maximumBytes
        else {
            throw CompanionRouteError(422, "invalid_inbox_file", "Inbox file is missing or exceeds its size limit")
        }
        return url
    }

    private func requiredBackupCategories(
        _ args: [String: CompanionJSONValue]?
    ) throws -> Set<BackupCategory> {
        let raw = try requiredStringArray(
            args, "categories", maximumCount: BackupCategory.allCases.count, maximumLength: 50)
        let categories = raw.compactMap(BackupCategory.init(rawValue:))
        guard categories.count == raw.count else {
            throw CompanionRouteError(422, "invalid_action_args", "Unknown backup category")
        }
        return Set(categories)
    }

    private func providerUUID(
        _ args: [String: CompanionJSONValue]?,
        expectedPrefix: String
    ) throws -> UUID {
        let raw = try requiredString(args, "id", maximum: 200)
        let prefix = expectedPrefix + ":"
        let uuidRaw = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        guard let id = UUID(uuidString: uuidRaw) else {
            throw CompanionRouteError(422, "invalid_provider_id", "Provider ID is invalid")
        }
        return id
    }

    private func parsedProviderUUID(_ providerID: String, prefix: String) -> UUID? {
        let expected = prefix + ":"
        guard providerID.hasPrefix(expected) else { return nil }
        return UUID(uuidString: String(providerID.dropFirst(expected.count)))
    }

    private func saveProviderAPIKey(_ apiKey: String, providerID: String) -> Bool {
        if let id = parsedProviderUUID(providerID, prefix: "transcription") {
            return APIKeyManager.shared.saveCustomModelAPIKey(apiKey, forModelId: id)
        }
        if let id = parsedProviderUUID(providerID, prefix: "enhancement") {
            return APIKeyManager.shared.saveCustomAIProviderAPIKey(apiKey, forProviderId: id)
        }
        guard let provider = AIProvider(rawValue: providerID), provider.requiresAPIKey else { return false }
        return APIKeyManager.shared.saveAPIKey(apiKey, forProvider: provider.rawValue)
    }

    private func deleteProviderAPIKey(providerID: String) -> Bool {
        if let id = parsedProviderUUID(providerID, prefix: "transcription") {
            return APIKeyManager.shared.deleteCustomModelAPIKey(forModelId: id)
        }
        if let id = parsedProviderUUID(providerID, prefix: "enhancement") {
            return APIKeyManager.shared.deleteCustomAIProviderAPIKey(forProviderId: id)
        }
        guard let provider = AIProvider(rawValue: providerID), provider.requiresAPIKey else { return false }
        return APIKeyManager.shared.deleteAPIKey(forProvider: provider.rawValue)
    }

    private func verifyProvider(_ providerID: String) async throws {
        let result: ConnectionTestResult
        if let id = parsedProviderUUID(providerID, prefix: "transcription") {
            guard let model = CustomCloudModelManager.shared.customModels.first(where: { $0.id == id }),
                let key = APIKeyManager.shared.getCustomModelAPIKey(forModelId: id), !key.isEmpty
            else {
                throw CompanionRouteError(409, "provider_key_required", "Provider configuration and API key are required")
            }
            result = await CustomModelConnectionTester.testTranscriptionEndpoint(
                endpoint: model.apiEndpoint, apiKey: key, modelName: model.modelName)
        } else if let id = parsedProviderUUID(providerID, prefix: "enhancement") {
            guard let provider = CustomAIProviderManager.shared.providers.first(where: { $0.id == id }),
                let key = APIKeyManager.shared.getCustomAIProviderAPIKey(forProviderId: id), !key.isEmpty
            else {
                throw CompanionRouteError(409, "provider_key_required", "Provider configuration and API key are required")
            }
            result = await CustomModelConnectionTester.testEnhancementEndpoint(
                baseURL: provider.baseURL, apiKey: key, modelName: provider.modelName)
        } else {
            guard let provider = AIProvider(rawValue: providerID),
                let key = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !key.isEmpty
            else {
                throw CompanionRouteError(409, "provider_key_required", "Provider API key is required")
            }
            let verification = await aiService.verifyAPIKey(
                key, for: provider, model: aiService.selectedModel(for: provider))
            if verification.isValid { return }
            providerVerificationStatus[providerID] = "failed"
            throw CompanionRouteError(
                422, "provider_verification_failed",
                String((verification.errorMessage ?? "Provider verification failed").prefix(500)))
        }
        switch result {
        case .success:
            return
        case .failure(let message):
            providerVerificationStatus[providerID] = "failed"
            throw CompanionRouteError(
                422, "provider_verification_failed", String(message.prefix(500)))
        }
    }

    private func backupFile(categories: Set<BackupCategory>) async throws -> BackupFile {
        let modes = categories.contains(.modes) ? ModeManager.shared.configurations : []
        let modeShortcuts = Dictionary(
            uniqueKeysWithValues: modes.compactMap { mode -> (String, ShortcutBackup)? in
                ShortcutStore.shortcut(for: .mode(mode.id)).map {
                    (mode.id.uuidString, ShortcutBackup($0))
                }
            })
        let words: [WordBackup]? =
            categories.contains(.dictionary)
            ? try modelContext.fetch(FetchDescriptor<VocabularyWord>()).map { WordBackup(word: $0.word) }
            : nil
        let replacements: [String: String]? =
            categories.contains(.dictionary)
            ? Dictionary(
                try modelContext.fetch(FetchDescriptor<WordReplacement>()).map {
                    ($0.originalText, $0.replacementText)
                },
                uniquingKeysWith: { _, last in last }
            )
            : nil
        let general: GeneralBackup? =
            categories.contains(.general)
            ? GeneralBackup(
                primaryRecordingShortcut: ShortcutStore.shortcut(for: .primaryRecording).map(ShortcutBackup.init),
                secondaryRecordingShortcut: ShortcutStore.shortcut(for: .secondaryRecording).map(ShortcutBackup.init),
                pasteLastTranscriptionShortcut: ShortcutStore.shortcut(for: .pasteLastTranscription).map(ShortcutBackup.init),
                pasteLastEnhancementShortcut: ShortcutStore.shortcut(for: .pasteLastEnhancement).map(ShortcutBackup.init),
                retryLastTranscriptionShortcut: ShortcutStore.shortcut(for: .retryLastTranscription).map(ShortcutBackup.init),
                cancelRecorderShortcut: ShortcutStore.shortcut(for: .cancelRecorder).map(ShortcutBackup.init),
                openHistoryWindowShortcut: ShortcutStore.shortcut(for: .openQuickHistory).map(ShortcutBackup.init),
                quickAddToDictionaryShortcut: ShortcutStore.shortcut(for: .quickAddToDictionary).map(ShortcutBackup.init),
                primaryRecordingShortcutRawValue: recordingShortcutManager.primaryRecordingShortcut.rawValue,
                secondaryRecordingShortcutRawValue: recordingShortcutManager.secondaryRecordingShortcut.rawValue,
                primaryRecordingShortcutModeRawValue: recordingShortcutManager.primaryRecordingShortcutMode.rawValue,
                secondaryRecordingShortcutModeRawValue: recordingShortcutManager.secondaryRecordingShortcutMode.rawValue,
                launchAtLoginEnabled: await launchAtLoginManager.currentEnabledStatus(),
                isMenuBarOnly: menuBarManager.isMenuBarOnly,
                recorderType: recorderUIManager.recorderPanelStyle.rawValue,
                appAppearancePreference: AppAppearancePreference.stored.rawValue,
                appLanguagePreference: AppLanguagePreference.storedRawValue,
                isTranscriptionCleanupEnabled: UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
                transcriptionRetentionMinutes: UserDefaults.standard.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes),
                isAudioCleanupEnabled: UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled),
                audioRetentionPeriod: UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod),
                isSystemMuteEnabled: MediaController.shared.isSystemMuteEnabled,
                isPauseMediaEnabled: PlaybackController.shared.isPauseMediaEnabled,
                audioResumptionDelay: MediaController.shared.audioResumptionDelay,
                isTextFormattingEnabled: UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled"),
                isExperimentalFeaturesEnabled: UserDefaults.standard.bool(forKey: "isExperimentalFeaturesEnabled"),
                restoreClipboardAfterPaste: UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste"),
                clipboardRestoreDelay: UserDefaults.standard.double(forKey: "clipboardRestoreDelay")
            )
            : nil
        return BackupFile(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            customPrompts: categories.contains(.prompts) ? enhancementService.customPrompts : [],
            modeConfigs: modes,
            modeShortcuts: modeShortcuts.isEmpty ? nil : modeShortcuts,
            vocabularyWords: words,
            wordReplacements: replacements,
            generalSettings: general,
            customEmojis: categories.contains(.modes) ? EmojiManager.shared.customEmojis : nil,
            customCloudModels: categories.contains(.customModels)
                ? CustomCloudModelManager.shared.customModels.map(CustomModelBackup.init)
                : nil
        )
    }

    private func storeArtifact(data: Data, contentType: String, filename: String) -> String {
        artifacts = artifacts.filter { $0.value.expiresAt > Date() }
        let id = UUID().uuidString
        artifacts[id] = CompanionArtifact(
            data: data,
            contentType: contentType,
            filename: filename,
            expiresAt: Date().addingTimeInterval(300)
        )
        return id
    }

    private func requiredUInt16(_ args: [String: CompanionJSONValue]?, _ key: String) throws -> UInt16 {
        let value = try requiredUnsigned(args, key, maximum: UInt64(UInt16.max))
        return UInt16(value)
    }

    private func requiredUInt(_ args: [String: CompanionJSONValue]?, _ key: String) throws -> UInt {
        UInt(try requiredUnsigned(args, key, maximum: UInt64(UInt.max)))
    }

    private func requiredUnsigned(
        _ args: [String: CompanionJSONValue]?,
        _ key: String,
        maximum: UInt64
    ) throws -> UInt64 {
        guard case .number(let value)? = args?[key], value.isFinite, value.rounded() == value,
            value >= 0, value <= Double(maximum)
        else { throw CompanionRouteError(400, "invalid_action_args", "\(key) requires a non-negative integer") }
        return UInt64(value)
    }

    private func parseSuggestions(_ text: String) -> [CompanionReviewSuggestion] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
            let payload = try? JSONDecoder.companion.decode(CompanionReviewProviderPayload.self, from: data)
        {
            return payload.suggestions
        }
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last,
            let data = String(trimmed[first...last]).data(using: .utf8),
            let payload = try? JSONDecoder.companion.decode(CompanionReviewProviderPayload.self, from: data)
        else { return [] }
        return payload.suggestions
    }

    private func recordingStateName(_ state: RecordingState) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .enhancing: return "enhancing"
        case .busy: return "busy"
        }
    }

    private func modelID(_ model: any TranscriptionModel) -> String {
        stableID("model:\(model.provider.rawValue):\(model.name)")
    }

    private func vocabularyID(_ word: String) -> String {
        stableID("vocabulary:\(word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))")
    }

    private func stableID(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).hexString
    }

    private func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(String(header.dropFirst("Bearer ".count)), token)
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            difference |= Int((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
        }
        return difference == 0
    }

    private func validatedText(_ value: String?, field: String, maximum: Int, allowEmpty: Bool = false) throws -> String {
        guard let value else { throw CompanionRouteError(400, "missing_field", "Missing \(field)") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty || !trimmed.isEmpty), trimmed.count <= maximum else {
            throw CompanionRouteError(422, "invalid_value", "\(field) is empty or exceeds its size limit")
        }
        return trimmed
    }

    private func boundedInteger(_ raw: String, field: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(raw), range.contains(value) else {
            throw CompanionRouteError(400, "invalid_query", "\(field) is outside its allowed range")
        }
        return value
    }

    private func exactInteger(_ value: Double, range: ClosedRange<Int>, field: String) throws -> Int {
        guard value.isFinite, value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw CompanionRouteError(422, "invalid_value", "\(field) requires an integer in its allowed range")
        }
        return Int(value)
    }

    private func companionJSONValue<T: Encodable>(_ value: T) throws -> CompanionJSONValue {
        let data = try JSONEncoder.companion.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try companionJSONValue(object)
    }

    private func companionJSONValue(_ value: Any) throws -> CompanionJSONValue {
        switch value {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(try value.map(companionJSONValue))
        case let value as [String: Any]:
            return .object(try value.mapValues(companionJSONValue))
        case is NSNull:
            return .null
        default:
            throw CompanionRouteError(500, "encoding_failed", "Native state could not be encoded")
        }
    }

    private func setting(
        _ key: String,
        _ label: String,
        _ type: String,
        _ value: CompanionJSONValue,
        _ options: [String]?,
        _ section: String
    ) -> CompanionSettingDescriptor {
        CompanionSettingDescriptor(key: key, label: label, type: type, value: value, options: options, section: section)
    }

    private func safeExtension(_ value: String) -> String {
        let filtered = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? "audio" : String(filtered.prefix(12))
    }

    private func audioContentType(extension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty else { throw CompanionRouteError(400, "missing_body", "Request body is required") }
        return try JSONDecoder.companion.decode(type, from: data)
    }

    private func json<T: Encodable>(_ value: T, statusCode: Int = 200) throws -> CompanionHTTPResponse {
        CompanionHTTPResponse(statusCode: statusCode, body: try JSONEncoder.companion.encode(value))
    }

    private func error(_ statusCode: Int, _ status: String, _ message: String) -> CompanionHTTPResponse {
        let body = (try? JSONEncoder.companion.encode(CompanionAPIError(status: status, message: message))) ?? Data()
        return CompanionHTTPResponse(statusCode: statusCode, body: body)
    }
}

private struct CompanionRouteError: Error {
    let statusCode: Int
    let status: String
    let message: String

    init(_ statusCode: Int, _ status: String, _ message: String) {
        self.statusCode = statusCode
        self.status = status
        self.message = message
    }
}

private struct CompanionDictionaryCanonical: Codable {
    let vocabulary: [CompanionVocabularyItem]
    let replacements: [CompanionReplacementItem]
}

private struct CompanionReviewComparison: Codable {
    let original: String
    let corrected: String
}

private struct CompanionArtifact {
    let data: Data
    let contentType: String
    let filename: String
    let expiresAt: Date
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
