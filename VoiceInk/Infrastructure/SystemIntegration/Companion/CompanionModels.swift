// ENSO ad-hoc local override: VoiceInk Companion API v1 approved 2026-10-01 assumes the current
// SwiftData entities and service names. Upstream schema, model identity, or API changes can make
// this stale; revalidate the SPEC contract, migrations, and isolated-store tests before reuse/update.

import Foundation

enum CompanionJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([CompanionJSONValue])
    case object([String: CompanionJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CompanionJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: CompanionJSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.typeMismatch(
                CompanionJSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a scalar JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct CompanionAPIError: Codable, Error, Sendable {
    let status: String
    let message: String
}

struct CompanionConnectionDescriptor: Codable, Sendable {
    let version: String
    let endpoint: String
    let token: String
}

struct CompanionCapabilityResponse: Codable {
    let version: String
    let sections: [String]
    let actions: [String]
    let actionDescriptors: [CompanionActionDescriptor]
}

struct CompanionActionDescriptor: Codable {
    let name: String
    let label: String
    let arguments: [CompanionActionArgumentDescriptor]
}

struct CompanionActionArgumentDescriptor: Codable {
    let name: String
    let type: String
    let required: Bool
    let options: [String]?
}

struct CompanionSettingDescriptor: Codable {
    let key: String
    let label: String
    let type: String
    let value: CompanionJSONValue
    let options: [String]?
    let section: String
}

struct CompanionModelDescriptor: Codable {
    let id: String
    let name: String
    let provider: String
    let available: Bool
    let downloaded: Bool
    let selected: Bool
    let downloading: Bool
    let downloadProgress: Double?
    let deletable: Bool
    let displayName: String
    let description: String
    let languages: [String: String]
    let multilingual: Bool
    let streaming: Bool
    let size: String?
    let speed: Double?
    let accuracy: Double?
    let ramUsage: Double?
    let publisher: String?
    let custom: Bool
    let keyConfigured: Bool
    let verificationStatus: String?
}

struct CompanionModeDescriptor: Codable {
    let id: String
    let name: String
    let isEnabled: Bool
    let isDefault: Bool
    let isActive: Bool
    let transcriptionModelName: String?
    let language: String?
    let enhancementEnabled: Bool
    let enhancementProvider: String?
    let enhancementModel: String?
    let promptID: String?
    let isRealtimeTranscriptionEnabled: Bool
    let isTextFormattingEnabled: Bool
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCapture: Bool
    let outputMode: String
    let autoSendKey: String
    let icon: CompanionJSONValue
    let order: Int
    let appConfigs: CompanionJSONValue
    let urlConfigs: CompanionJSONValue
    let triggerGroups: CompanionJSONValue
    let triggerWords: [String]
    let customCommand: String?
}

struct CompanionProviderDescriptor: Codable {
    let id: String
    let name: String
    let connected: Bool
    let selected: Bool
    let models: [String]
    let selectedModel: String
    let kind: String
    let baseURL: String?
    let requiresAPIKey: Bool
    let keyConfigured: Bool
    let verificationStatus: String?
    let custom: Bool
    let enabled: Bool
}

struct CompanionPromptDescriptor: Codable {
    let id: String
    let title: String
    let promptText: String
    let useSystemInstructions: Bool
}

struct CompanionAudioDeviceDescriptor: Codable {
    let uid: String
    let name: String
    let selected: Bool
    let prioritized: Bool
    let priority: Int?
}

struct CompanionAudioInputState: Codable {
    let mode: String
    let selectedUID: String?
    let devices: [CompanionAudioDeviceDescriptor]
}

struct CompanionShortcutDescriptor: Codable {
    let action: String
    let label: String
    let kind: String?
    let keyCode: Int?
    let modifiers: Double?
    let display: String
}

struct CompanionShortcutCaptureState: Codable {
    let status: String
    let action: String?
    let display: String?
    let expiresAt: Date?
}

struct CompanionAudioTranscriptionItem: Codable {
    let id: String
    let filename: String
    let status: String
    let phase: String?
    let transcriptionID: String?
    let errorMessage: String?
}

struct CompanionAudioTranscriptionState: Codable {
    let isProcessing: Bool
    let items: [CompanionAudioTranscriptionItem]
}

struct CompanionStateMetadata: Codable {
    let pendingModelID: String?
    let activeTranscriptionModelID: String?
    let historyCount: Int
    let dictionaryRevision: String
}

struct CompanionStateProgress: Codable {
    let kind: String?
    let status: String
    let message: String?
}

struct CompanionPermissionDescriptor: Codable {
    let status: String
    let granted: Bool
}

struct CompanionPermissionsState: Codable {
    let accessibility: CompanionPermissionDescriptor
    let microphone: CompanionPermissionDescriptor
    let screenCapture: CompanionPermissionDescriptor
}

struct CompanionDashboardPeriodState: Codable {
    let totalCount: Int
    let totalWords: Int
    let totalDuration: Double
    let productivity: CompanionJSONValue
    let modelUsage: CompanionJSONValue
    let modelPerformance: CompanionJSONValue
    let peakHours: CompanionJSONValue
}

struct CompanionDashboardSummary: Codable {
    let today: CompanionDashboardPeriodState
    let lastSevenDays: CompanionDashboardPeriodState
    let lastThirtyDays: CompanionDashboardPeriodState
    let thisYear: CompanionDashboardPeriodState
    let allTime: CompanionDashboardPeriodState
}

struct CompanionDashboardState: Codable {
    let summary: CompanionDashboardSummary?
    let generatedAt: Date?
    let sourceMetricCount: Int
    let isStale: Bool
    let displayName: String
    let permissions: CompanionPermissionsState
}

struct CompanionSoundState: Codable {
    let selection: String
    let builtInID: String?
    let customConfigured: Bool
}

struct CompanionAudioState: Codable {
    let input: CompanionAudioInputState
    let prioritizedDeviceUIDs: [String]
    let pauseMediaDuringRecording: Bool
    let muteSystemDuringRecording: Bool
    let audioResumptionDelay: Double
    let startSound: CompanionSoundState
    let stopSound: CompanionSoundState
}

struct CompanionBackupState: Codable {
    let categories: [String]
    let maximumImportBytes: Int
}

struct CompanionLicenseState: Codable {
    let status: String
    let isPro: Bool
    let trialDaysRemaining: Int?
}

struct CompanionStateResponse: Codable {
    let version: String
    let recordingState: String
    let settings: [CompanionSettingDescriptor]
    let models: [CompanionModelDescriptor]
    let modes: [CompanionModeDescriptor]
    let providers: [CompanionProviderDescriptor]
    let prompts: [CompanionPromptDescriptor]
    let audioInput: CompanionAudioInputState
    let shortcuts: [CompanionShortcutDescriptor]
    let shortcutCapture: CompanionShortcutCaptureState
    let audioTranscription: CompanionAudioTranscriptionState
    let metadata: CompanionStateMetadata
    let progress: CompanionStateProgress
    let dashboard: CompanionDashboardState
    let audio: CompanionAudioState
    let backup: CompanionBackupState
    let license: CompanionLicenseState
}

struct CompanionVocabularyItem: Codable {
    let id: String
    let word: String
    let dateAdded: Date
}

struct CompanionReplacementItem: Codable {
    let id: String
    let originalText: String
    let replacementText: String
    let isEnabled: Bool
    let dateAdded: Date
}

struct CompanionDictionaryResponse: Codable {
    let revision: String
    let vocabulary: [CompanionVocabularyItem]
    let replacements: [CompanionReplacementItem]
}

struct CompanionDictionaryOperation: Codable {
    let kind: String
    let action: String
    let id: String?
    let word: String?
    let originalText: String?
    let replacementText: String?
    let isEnabled: Bool?
}

struct CompanionDictionaryMutationRequest: Codable {
    let expectedRevision: String
    let operations: [CompanionDictionaryOperation]
}

struct CompanionHistoryItem: Codable {
    let id: String
    let text: String
    let enhancedText: String?
    let timestamp: Date
    let duration: TimeInterval
    let hasAudio: Bool
    let audioFileURL: String?
    let audioFileExtension: String?
    let transcriptionDuration: TimeInterval?
    let enhancementDuration: TimeInterval?
    let transcriptionModelName: String?
    let aiEnhancementModelName: String?
    let promptName: String?
    let modeName: String?
    let transcriptionStatus: String?
}

struct CompanionHistoryResponse: Codable {
    let items: [CompanionHistoryItem]
    let nextOffset: Int?
    let total: Int
    let query: String?
}

struct CompanionSettingMutationRequest: Codable {
    let key: String
    let value: CompanionJSONValue
}

struct CompanionModelSelectionRequest: Codable {
    let id: String
}

struct CompanionModelSelectionResponse: Codable {
    let status: String
    let id: String
}

struct CompanionActionRequest: Codable {
    let action: String
    let args: [String: CompanionJSONValue]?
}

struct CompanionActionResponse: Codable {
    let status: String
    let action: String
    let id: String?
}

struct CompanionReviewRequest: Codable {
    let original: String
    let corrected: String
}

struct CompanionReviewSuggestion: Codable {
    let original: String
    let corrected: String
    let reason: String
}

struct CompanionReviewResponse: Codable {
    let suggestions: [CompanionReviewSuggestion]
}

struct CompanionReviewProviderPayload: Codable {
    let suggestions: [CompanionReviewSuggestion]
}
