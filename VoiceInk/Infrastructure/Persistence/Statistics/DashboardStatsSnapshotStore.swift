import Foundation
import os

final class DashboardStatsSnapshotStore: @unchecked Sendable {
    static let shared = DashboardStatsSnapshotStore()

    struct CachedSnapshot: Sendable {
        let metadata: Metadata
        let summary: DashboardStatsSummary
    }

    struct Metadata: Codable, Sendable {
        let version: Int
        let generatedAt: Date
        let metricCount: Int
        let localeIdentifier: String
        let timeZoneIdentifier: String

        var matchesCurrentEnvironment: Bool {
            version == DashboardStatsSnapshotStore.currentVersion && localeIdentifier == Locale.current.identifier
                && timeZoneIdentifier == TimeZone.current.identifier
        }

        func wasGeneratedInCurrentDashboardDay(
            now: Date = Date(),
            calendar: Calendar = DashboardPeriodWindows.dashboardCalendar()
        ) -> Bool {
            calendar.isDate(generatedAt, inSameDayAs: now)
        }
    }

    private struct Snapshot: Codable, Sendable {
        let metadata: Metadata
        let summary: DashboardStatsSummary
    }

    private static let currentVersion = 1
    private static let staleDefaultsKey = "dashboardStatsSnapshotStale"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "DashboardStatsSnapshotStore")
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let snapshotURL: URL
    private let saveQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.dashboardStatsSnapshotStore", qos: .utility)

    private init(fileManager: FileManager = .default, userDefaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        // ENSO ad-hoc local override: dashboard snapshots must follow the same production or
        // CompanionTest root as SwiftData and recordings. Upstream snapshot/storage changes can
        // make this stale; revalidate read/write isolation before sandbox reuse/update.
        let appSupportURL = (try? CompanionEnvironment.applicationSupportRoot(fileManager: fileManager))
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/com.prakashjoshipax.VoiceInk", isDirectory: true)
        self.snapshotURL = appSupportURL.appendingPathComponent("dashboard-stats-snapshot.json")
    }

    func loadSnapshot() -> CachedSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            let cachedSnapshot = CachedSnapshot(metadata: snapshot.metadata, summary: snapshot.summary)

            guard cachedSnapshot.metadata.matchesCurrentEnvironment else {
                return nil
            }
            return cachedSnapshot
        } catch {
            logger.error("Failed to load dashboard stats snapshot: \(error, privacy: .public)")
            return nil
        }
    }

    func saveSummary(_ summary: DashboardStatsSummary) -> Metadata {
        let snapshotURL = snapshotURL
        let logger = logger
        let userDefaults = userDefaults
        let metadata = Metadata(
            version: Self.currentVersion,
            generatedAt: Date(),
            metricCount: summary.totalCount,
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        let snapshot = Snapshot(
            metadata: metadata,
            summary: summary
        )

        saveQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: snapshotURL, options: [.atomic])
                userDefaults.removeObject(forKey: Self.staleDefaultsKey)
            } catch {
                logger.error("Failed to save dashboard stats snapshot: \(error, privacy: .public)")
            }
        }

        return metadata
    }

    func markStale() {
        userDefaults.set(true, forKey: Self.staleDefaultsKey)
    }

    func isMarkedStale() -> Bool {
        userDefaults.bool(forKey: Self.staleDefaultsKey)
    }
}
