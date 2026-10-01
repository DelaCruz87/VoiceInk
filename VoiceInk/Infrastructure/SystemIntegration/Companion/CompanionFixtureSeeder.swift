// ENSO ad-hoc local override: deterministic synthetic seed for Companion E2E verification.
// It assumes current SwiftData models and a separately identified CompanionTest app bundle.
// Schema, bundle identity, or fixture-contract changes can make this stale; revalidate that all
// files/stores/defaults remain isolated and that no user transcript is read before reuse/update.

import Foundation
import SwiftData

@MainActor
enum CompanionFixtureSeeder {
    private static let transcriptionID = UUID(uuidString: "E2E00000-0000-4000-8000-000000000001")!
    private static let replacementID = UUID(uuidString: "E2E00000-0000-4000-8000-000000000002")!
    private static let transcriptionModelID = UUID(uuidString: "E2E00000-0000-4000-8000-000000000003")!
    private static let enhancementProviderID = UUID(uuidString: "E2E00000-0000-4000-8000-000000000004")!
    private static let pendingTranscriptionModelID = UUID(uuidString: "E2E00000-0000-4000-8000-000000000005")!
    private static let modeID = UUID(uuidString: "E2E00000-0000-4000-8000-000000000006")!

    static func seedIfRequested(
        modelContext: ModelContext,
        transcriptionModelManager: TranscriptionModelManager,
        aiService: AIService
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[CompanionEnvironment.fixtureSeedVariable] == "1" else { return }
        guard environment[CompanionEnvironment.dataDirectoryVariable]?.isEmpty == false,
            Bundle.main.bundleIdentifier?.hasSuffix(".CompanionTest") == true
        else {
            throw CompanionAPIError(
                status: "unsafe_fixture_configuration",
                message: "Fixture seed requires an isolated data directory and CompanionTest bundle identity"
            )
        }

        let recordingsDirectory = try CompanionEnvironment.recordingsDirectory()
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let audioURL = recordingsDirectory.appendingPathComponent("companion-e2e-synthetic.wav")
        let audioData = syntheticWAV()
        try audioData.write(to: audioURL, options: .atomic)

        let inboxDirectory = try CompanionEnvironment.importInboxDirectory()
        try FileManager.default.createDirectory(
            at: inboxDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try audioData.write(
            to: inboxDirectory.appendingPathComponent("companion-e2e-input.wav"),
            options: .atomic
        )

        if let rawProviderURL = environment[CompanionEnvironment.fixtureProviderURLVariable],
            let providerURL = URL(string: rawProviderURL),
            providerURL.scheme == "http",
            providerURL.host == "127.0.0.1"
        {
            let customModel = CustomCloudModel(
                id: transcriptionModelID,
                name: "companion-fixture-asr",
                displayName: "Companion Fixture ASR",
                description: "Synthetic loopback fixture",
                apiEndpoint: providerURL.appendingPathComponent("v1/audio/transcriptions").absoluteString,
                modelName: "companion-fixture-asr"
            )
            let customModelManager = CustomCloudModelManager.shared
            customModelManager.customModels.removeAll {
                $0.id == transcriptionModelID || $0.id == pendingTranscriptionModelID
            }
            customModelManager.customModels.append(customModel)
            customModelManager.customModels.append(
                CustomCloudModel(
                    id: pendingTranscriptionModelID,
                    name: "companion-fixture-after-idle",
                    displayName: "Companion Fixture After Idle",
                    description: "Synthetic pending-selection fixture",
                    apiEndpoint: providerURL.appendingPathComponent("v1/audio/transcriptions").absoluteString,
                    modelName: "companion-fixture-after-idle"
                )
            )
            customModelManager.saveCustomModels()
            transcriptionModelManager.refreshAllAvailableModels()

            let fixtureMode = ModeConfig(
                id: modeID,
                name: "Companion Fixture Mode",
                isAIEnhancementEnabled: false,
                selectedTranscriptionModelName: customModel.name,
                isRealtimeTranscriptionEnabled: false,
                selectedLanguage: "en",
                useSelectedTextContext: false,
                isEnabled: true,
                isDefault: true
            )
            let modeManager = ModeManager.shared
            if modeManager.configurations.contains(where: { $0.id == modeID }) {
                modeManager.updateConfiguration(fixtureMode)
            } else {
                modeManager.addConfiguration(fixtureMode)
            }
            modeManager.setAsDefault(configId: modeID)
            modeManager.setActiveConfiguration(fixtureMode)

            let provider = CustomAIProviderConfig(
                id: enhancementProviderID,
                name: "Companion Fixture Review",
                baseURL: providerURL.appendingPathComponent("v1/chat/completions").absoluteString,
                models: ["companion-fixture-review"],
                selectedModel: "companion-fixture-review"
            )
            let providerManager = CustomAIProviderManager.shared
            if providerManager.providers.contains(where: { $0.id == enhancementProviderID }) {
                guard providerManager.updateProvider(provider, apiKey: "companion-fixture-only") else {
                    throw CompanionAPIError(status: "fixture_provider_failed", message: "Could not update fixture provider")
                }
            } else {
                guard providerManager.addProvider(provider, apiKey: "companion-fixture-only") else {
                    throw CompanionAPIError(status: "fixture_provider_failed", message: "Could not add fixture provider")
                }
            }
            aiService.selectedProvider = .custom
            aiService.selectModel("companion-fixture-review", for: .custom)
        }

        let transcriptions = try modelContext.fetch(FetchDescriptor<Transcription>())
        let transcription: Transcription
        if let existing = transcriptions.first(where: { $0.id == transcriptionID }) {
            transcription = existing
        } else {
            transcription = Transcription(
                text: "Companion synthetic transcript, ni\u{00F1}o | line one.\nLine two.",
                duration: 0.1,
                enhancedText: "Companion synthetic transcript, ni\u{00F1}o, line one. Line two.",
                audioFileURL: audioURL.absoluteString,
                transcriptionModelName: "Companion Fixture",
                aiEnhancementModelName: "Companion Fixture",
                promptName: "Companion Fixture",
                transcriptionDuration: 0.01,
                enhancementDuration: 0.01,
                modeName: "Companion Fixture",
                transcriptionStatus: .completed
            )
            transcription.id = transcriptionID
            transcription.timestamp = Date(timeIntervalSince1970: 1_759_320_000)
            modelContext.insert(transcription)
        }
        transcription.audioFileURL = audioURL.absoluteString

        let vocabulary = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
        if !vocabulary.contains(where: { $0.word == "CompanionSyntheticVocabulary" }) {
            modelContext.insert(
                VocabularyWord(
                    word: "CompanionSyntheticVocabulary",
                    dateAdded: Date(timeIntervalSince1970: 1_759_320_000)
                )
            )
        }

        let replacements = try modelContext.fetch(FetchDescriptor<WordReplacement>())
        if !replacements.contains(where: { $0.id == replacementID }) {
            let replacement = WordReplacement(
                originalText: "CompanionSyntheticOriginal",
                replacementText: "CompanionSyntheticReplacement",
                dateAdded: Date(timeIntervalSince1970: 1_759_320_001),
                isEnabled: false
            )
            replacement.id = replacementID
            modelContext.insert(replacement)
        }

        let metrics = try modelContext.fetch(FetchDescriptor<SessionMetric>())
        if !metrics.contains(where: { $0.transcriptionId == transcriptionID }) {
            modelContext.insert(
                SessionMetric(
                    transcriptionId: transcriptionID,
                    timestamp: Date(timeIntervalSince1970: 1_759_320_000),
                    source: "companion-fixture",
                    wordCount: 9,
                    audioDuration: 0.1,
                    transcriptionModelName: "Companion Fixture",
                    transcriptionDuration: 0.01,
                    speedFactor: 10,
                    modeName: "Companion Fixture",
                    aiEnhancementModelName: "Companion Fixture",
                    enhancementDuration: 0.01,
                    enhancementEstimatedTokenCount: 12
                )
            )
        }

        if modelContext.hasChanges { try modelContext.save() }
    }

    private static func syntheticWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = 800
        let dataByteCount = UInt32(sampleCount * Int(bitsPerSample / 8))
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)

        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(Data("data".utf8))
        data.appendLittleEndian(dataByteCount)
        data.append(Data(repeating: 0, count: Int(dataByteCount)))
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
