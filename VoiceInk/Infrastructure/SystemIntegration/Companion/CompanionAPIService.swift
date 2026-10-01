// ENSO ad-hoc local override: VoiceInk Companion API v1 approved 2026-10-01 assumes the current
// VoiceInkEngine, model managers, ModeManager, enhancement provider, and SwiftData entities.
// Upstream lifecycle/schema/service changes can make this stale; revalidate native effects,
// revision conflicts, model queuing, history/audio identity, and review provider behavior.

import Combine
import CryptoKit
import AppKit
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
    private let token: String
    private var pendingModelID: String?
    private var lastModelSelectionError: String?
    private var recordingStateObserver: AnyCancellable?
    private var audioTranscriptionObserver: AnyCancellable?

    init(
        modelContext: ModelContext,
        engine: VoiceInkEngine,
        transcriptionModelManager: TranscriptionModelManager,
        whisperModelManager: WhisperModelManager,
        fluidAudioModelManager: FluidAudioModelManager,
        aiService: AIService,
        enhancementService: AIEnhancementService,
        token: String
    ) {
        self.modelContext = modelContext
        self.engine = engine
        self.transcriptionModelManager = transcriptionModelManager
        self.whisperModelManager = whisperModelManager
        self.fluidAudioModelManager = fluidAudioModelManager
        self.aiService = aiService
        self.enhancementService = enhancementService
        self.token = token

        recordingStateObserver = engine.$recordingState.sink { [weak self] state in
            guard state == .idle else { return }
            Task { @MainActor [weak self] in self?.applyPendingModelIfPossible() }
        }
        audioTranscriptionObserver = AudioTranscriptionManager.shared.$isProcessingQueue.sink { [weak self] isProcessing in
            guard !isProcessing else { return }
            Task { @MainActor [weak self] in self?.applyPendingModelIfPossible() }
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
                return try json(try performAction(action))

            case ("POST", "/v1/review"):
                let review = try decode(CompanionReviewRequest.self, from: request.body)
                return try json(try await reviewSuggestions(review))

            default:
                if request.method == "GET", path.hasPrefix("/v1/history/"), path.hasSuffix("/audio") {
                    return try audioResponse(path: path)
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
            modes: modeDescriptors(),
            providers: providerDescriptors(),
            prompts: promptDescriptors(),
            audioInput: audioInputState(),
            shortcuts: shortcutDescriptors(),
            audioTranscription: audioTranscriptionState(),
            metadata: CompanionStateMetadata(
                pendingModelID: pendingModelID,
                activeTranscriptionModelID: selectedID,
                historyCount: historyCount,
                dictionaryRevision: dictionary.revision
            ),
            progress: CompanionStateProgress(
                kind: pendingModelID == nil && lastModelSelectionError == nil ? nil : "modelSelection",
                status: pendingModelID != nil ? "pending" : (lastModelSelectionError == nil ? "idle" : "failed"),
                message: lastModelSelectionError
            )
        )
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
            guard item.name == "offset" || item.name == "limit", query[item.name] == nil else {
                throw CompanionRouteError(400, "invalid_query", "History query keys must be unique and supported")
            }
            query[item.name] = item.value ?? ""
        }
        let offset = try boundedInteger(query["offset"] ?? "0", field: "offset", range: 0...Int.max)
        let limit = try boundedInteger(query["limit"] ?? "100", field: "limit", range: 1...500)
        let all = try modelContext.fetch(FetchDescriptor<Transcription>()).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        let start = min(offset, all.count)
        let end = min(start + limit, all.count)
        let items = all[start..<end].map {
            CompanionHistoryItem(
                id: $0.id.uuidString,
                text: $0.text,
                enhancedText: $0.enhancedText,
                timestamp: $0.timestamp,
                duration: $0.duration,
                audioFileURL: $0.audioFileURL,
                transcriptionModelName: $0.transcriptionModelName,
                aiEnhancementModelName: $0.aiEnhancementModelName,
                promptName: $0.promptName,
                modeName: $0.modeName,
                transcriptionStatus: $0.transcriptionStatus
            )
        }
        return CompanionHistoryResponse(items: Array(items), nextOffset: end < all.count ? end : nil, total: all.count)
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
        return transcriptionModelManager.allAvailableModels.map { model in
            let id = modelID(model)
            let download = modelDownloadState(model)
            return CompanionModelDescriptor(
                id: id,
                name: model.name,
                provider: model.provider.rawValue,
                available: transcriptionModelManager.isAvailableOnCurrentOS(model),
                downloaded: usableIDs.contains(id),
                selected: selectedID == id,
                downloading: download.downloading,
                downloadProgress: download.progress,
                deletable: download.local && usableIDs.contains(id)
            )
        }.sorted { lhs, rhs in
            lhs.provider == rhs.provider ? lhs.name < rhs.name : lhs.provider < rhs.provider
        }
    }

    private func modeDescriptors() -> [CompanionModeDescriptor] {
        let manager = ModeManager.shared
        return manager.configurations.map { mode in
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
                autoSendKey: mode.autoSendKey.rawValue
            )
        }
    }

    private func providerDescriptors() -> [CompanionProviderDescriptor] {
        let connected = Set(aiService.connectedProviders)
        return AIProvider.allCases.filter(\.supportsEnhancement).map { provider in
            CompanionProviderDescriptor(
                id: provider.rawValue,
                name: provider.rawValue,
                connected: connected.contains(provider),
                selected: aiService.selectedProvider == provider,
                models: aiService.availableModels(for: provider),
                selectedModel: aiService.selectedModel(for: provider)
            )
        }
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
            switch item.status {
            case .pending: state = ("pending", nil)
            case .processing(let phase): state = ("processing", phase.rawValue)
            case .completed: state = ("completed", nil)
            case .failed: state = ("failed", nil)
            }
            return CompanionAudioTranscriptionItem(
                id: item.id.uuidString,
                filename: item.filename,
                status: state.0,
                phase: state.1,
                transcriptionID: item.transcription?.id.uuidString
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
            action("downloadModel", "Download transcription model", [arg("id", "string")]),
            action("deleteModel", "Delete transcription model", [arg("id", "string")]),
            action("transcribeAudio", "Transcribe audio file", [arg("path", "string"), arg("modeID", "string", false)]),
            action("cancelAudioTranscription", "Cancel audio transcription"),
            action("retryAudioTranscription", "Retry audio transcription", [arg("id", "string")]),
            action("clearAudioTranscriptionQueue", "Clear audio transcription queue"),
        ]
    }

    private func selectModel(_ id: String) throws -> CompanionModelSelectionResponse {
        guard let model = transcriptionModelManager.allAvailableModels.first(where: { modelID($0) == id }) else {
            throw CompanionRouteError(404, "model_not_found", "Unknown transcription model")
        }
        guard transcriptionModelManager.usableModels.contains(where: { modelID($0) == modelID(model) }) else {
            throw CompanionRouteError(409, "model_unavailable", "The model is not currently usable")
        }
        if engine.recordingState != .idle || AudioTranscriptionManager.shared.isProcessingQueue {
            pendingModelID = id
            lastModelSelectionError = nil
            return CompanionModelSelectionResponse(status: "pending", id: id)
        }
        try applyModel(id)
        lastModelSelectionError = nil
        return CompanionModelSelectionResponse(status: "applied", id: id)
    }

    private func applyPendingModelIfPossible() {
        guard engine.recordingState == .idle,
            !AudioTranscriptionManager.shared.isProcessingQueue,
            let id = pendingModelID
        else { return }
        do {
            try applyModel(id)
            pendingModelID = nil
        } catch {
            pendingModelID = nil
            lastModelSelectionError = "The pending model could not be applied"
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

    private func performAction(_ request: CompanionActionRequest) throws -> CompanionActionResponse {
        var responseID: String?
        var responseStatus = "applied"
        switch request.action {
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
            guard let provider = AIProvider(rawValue: rawProvider), provider.supportsEnhancement else {
                throw CompanionRouteError(400, "invalid_action_args", "Unknown enhancement provider")
            }
            aiService.selectedProvider = provider
            responseID = provider.rawValue
        case "selectEnhancementModel":
            let rawProvider = try requiredString(request.args, "provider", maximum: 100)
            let model = try requiredString(request.args, "model", maximum: 500)
            guard let provider = AIProvider(rawValue: rawProvider), provider.supportsEnhancement,
                aiService.availableModels(for: provider).contains(model)
                    || (provider == .localCLI && model == provider.defaultModel)
            else {
                throw CompanionRouteError(422, "invalid_action_args", "Enhancement model is unavailable")
            }
            aiService.selectModel(model, for: provider)
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
        case "downloadModel":
            let id = try requiredString(request.args, "id", maximum: 200)
            try startModelDownload(id)
            responseID = id
            responseStatus = "pending"
        case "deleteModel":
            let id = try requiredString(request.args, "id", maximum: 200)
            if try deleteModel(id) { responseStatus = "pending" }
            responseID = id
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

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
