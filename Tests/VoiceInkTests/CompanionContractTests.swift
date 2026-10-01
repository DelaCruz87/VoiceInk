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
}
