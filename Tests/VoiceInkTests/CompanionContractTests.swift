// ENSO ad-hoc local override: these tests lock the VoiceInk Companion parity contract approved
// 2026-10-01. Upstream API/model changes can make them stale; revalidate SPEC, payload bounds,
// private-data handling, and service-backed effects before reuse/update.

import Foundation
import Testing
@testable import VoiceInk

struct CompanionContractTests {
    @Test
    func jsonValueRoundTripsTypedArraysAndObjects() throws {
        let value: CompanionJSONValue = .object([
            "ids": .array([.string("a"), .string("b")]),
            "enabled": .bool(true),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(CompanionJSONValue.self, from: data) == value)
    }

    @Test
    func historyResponseCarriesSearchAndNativeTimingFields() throws {
        let item = CompanionHistoryItem(
            id: UUID().uuidString,
            text: "fixture",
            enhancedText: nil,
            timestamp: Date(timeIntervalSince1970: 1),
            duration: 2,
            hasAudio: true,
            audioFileURL: "/v1/history/fixture/audio",
            audioFileExtension: "wav",
            transcriptionDuration: 0.25,
            enhancementDuration: 0.5,
            transcriptionModelName: "Fixture",
            aiEnhancementModelName: nil,
            promptName: nil,
            modeName: "Default",
            transcriptionStatus: "completed"
        )
        let response = CompanionHistoryResponse(items: [item], nextOffset: nil, total: 1, query: "fix")
        let decoded = try JSONDecoder().decode(
            CompanionHistoryResponse.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decoded.query == "fix")
        #expect(decoded.items.first?.hasAudio == true)
        #expect(decoded.items.first?.transcriptionDuration == 0.25)
        #expect(decoded.items.first?.enhancementDuration == 0.5)
    }

    @Test
    func dashboardSummaryEncodesBreakdownsInsideEveryPeriod() throws {
        let period = CompanionDashboardPeriodState(
            totalCount: 2,
            totalWords: 10,
            totalDuration: 3,
            productivity: .array([]),
            modelUsage: .object([:]),
            modelPerformance: .array([]),
            peakHours: .object([:])
        )
        let summary = CompanionDashboardSummary(
            today: period,
            lastSevenDays: period,
            lastThirtyDays: period,
            thisYear: period,
            allTime: period
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
        #expect(object?["today"] as? [String: Any] != nil)
        #expect((object?["allTime"] as? [String: Any])?["modelUsage"] != nil)
        #expect((object?["lastThirtyDays"] as? [String: Any])?["peakHours"] != nil)
    }

    @Test
    func appleSpeechDescriptorCarriesNativeCatalogMetadataAndOrder() throws {
        let descriptor = CompanionModelDescriptor(
            id: "Native Apple::apple-speech",
            order: 1,
            name: "apple-speech",
            provider: "Native Apple",
            builtin: true,
            platform: "macOS 26+",
            onDevice: true,
            available: true,
            downloaded: true,
            selected: false,
            downloading: false,
            downloadProgress: nil,
            deletable: false,
            displayName: "Apple Speech",
            description: "fixture",
            languages: ["en": "English"],
            multilingual: true,
            streaming: false,
            size: nil,
            speed: nil,
            accuracy: nil,
            ramUsage: nil,
            publisher: nil,
            custom: false,
            keyConfigured: false,
            verificationStatus: nil
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any]
        #expect(object?["order"] as? Int == 1)
        #expect(object?["builtin"] as? Bool == true)
        #expect(object?["platform"] as? String == "macOS 26+")
        #expect(object?["onDevice"] as? Bool == true)
        #expect(object?["deletable"] as? Bool == false)
    }

    @Test
    func refinementModelHasIndependentEnhancementLifecycleContract() throws {
        let descriptor = CompanionRefinementModelDescriptor(
            id: "voiceink-refine-v1",
            order: 0,
            name: "VoiceInk Refine V1",
            displayName: "VoiceInk Refine V1",
            provider: "VoiceInk Refine",
            kind: "enhancement",
            badge: "New",
            description: "fixture",
            platform: "Apple silicon",
            onDevice: true,
            minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            size: "fixture",
            available: true,
            availabilityStatus: "available",
            unavailableDescription: nil,
            downloaded: true,
            selected: true,
            selectable: true,
            downloading: false,
            finalizing: false,
            downloadProgress: 1,
            downloadedBytes: 1,
            totalDownloadBytes: 1,
            downloadStatus: "downloaded",
            deletable: true,
            supportedActions: [
                "deleteRefinementModel",
                "selectEnhancementProvider",
                "selectEnhancementModel",
            ]
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any]
        #expect(object?["kind"] as? String == "enhancement")
        #expect(object?["order"] as? Int == 0)
        #expect(object?["name"] as? String == "VoiceInk Refine V1")
        #expect((object?["supportedActions"] as? [String])?.contains("deleteRefinementModel") == true)
        #expect((object?["supportedActions"] as? [String])?.contains("downloadModel") == false)
    }

    @Test
    func enhancementSelectionQueueKeepsEffectiveStateUntilIdleAndAppliesLatest() {
        var queue = CompanionEnhancementSelectionQueue()
        var effectiveProvider = "Gemini"
        var effectiveModel = "gemini-fixture"

        queue.enqueue(
            CompanionPendingEnhancementSelection(
                action: "provider",
                provider: "VoiceInk Refine",
                model: nil
            ))
        #expect(queue.takeIfIdle(false) == nil)
        #expect(effectiveProvider == "Gemini")
        #expect(effectiveModel == "gemini-fixture")

        let latest = CompanionPendingEnhancementSelection(
            action: "model",
            provider: "Ollama",
            model: "local-fixture"
        )
        queue.enqueue(latest)
        #expect(queue.pending == latest)
        #expect(queue.takeIfIdle(false) == nil)
        #expect(queue.pending == latest)

        let applied = queue.takeIfIdle(true)
        if let applied {
            effectiveProvider = applied.provider
            effectiveModel = applied.model ?? effectiveModel
        }
        #expect(applied == latest)
        #expect(effectiveProvider == "Ollama")
        #expect(effectiveModel == "local-fixture")
        #expect(queue.pending == nil)
    }
}
