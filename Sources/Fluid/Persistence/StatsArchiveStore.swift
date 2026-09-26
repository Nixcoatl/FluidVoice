import Combine
import Foundation

/// Numbers-only summary of a deleted history entry, so stats survive clearing history.
/// Never stores transcript text.
nonisolated struct ArchivedDictationStats: Codable, Sendable {
    let timestamp: Date
    let words: Int
    let characters: Int
    let appName: String
    let audioMilliseconds: Int?
    let wasAIProcessed: Bool
    let usedFluidIntelligence: Bool
    let fluidFixedWords: Int
}

nonisolated struct StatsArchive: Codable, Sendable {
    var archivedDictations: [ArchivedDictationStats] = []
    /// Every dictation cancelled with Esc, short or long.
    var cancellations: [Date] = []
    /// History entries kept from a long cancelled dictation; they are not counted as dictations.
    var cancelledEntryIDs: Set<UUID> = []

    var isEmpty: Bool {
        self.archivedDictations.isEmpty && self.cancellations.isEmpty
    }
}

@MainActor
final class StatsArchiveStore: ObservableObject {
    static let shared = StatsArchiveStore()

    @Published private(set) var archive: StatsArchive
    private let fileURL: URL?

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidVoice", isDirectory: true)
        self.fileURL = directory?.appendingPathComponent("StatsArchive.json", isDirectory: false)
        if let fileURL = self.fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(StatsArchive.self, from: data)
        {
            self.archive = decoded
        } else {
            self.archive = StatsArchive()
        }
    }

    func recordCancellation(at date: Date = Date()) {
        self.archive.cancellations.append(date)
        self.save()
    }

    func markCancelledEntry(_ id: UUID) {
        self.archive.cancelledEntryIDs.insert(id)
        self.save()
    }

    /// Call before entries leave history so their numbers keep counting in Stats.
    func archiveRemovedEntries(_ entries: [TranscriptionHistoryEntry]) {
        guard !entries.isEmpty else { return }
        let dictations = entries.filter { !self.archive.cancelledEntryIDs.contains($0.id) }
        self.archive.archivedDictations += dictations.map { entry in
            let usedFluid = entry.wasAIProcessed && entry.processingModel?.lowercased().hasPrefix("fluid-1") == true
            return ArchivedDictationStats(
                timestamp: entry.timestamp,
                words: StatsSnapshot.wordCount(entry.processedText),
                characters: entry.processedText.count,
                appName: entry.appName,
                audioMilliseconds: entry.audio?.durationMilliseconds,
                wasAIProcessed: entry.wasAIProcessed,
                usedFluidIntelligence: usedFluid,
                fluidFixedWords: usedFluid ? StatsSnapshot.changedWordCount(raw: entry.rawText, processed: entry.processedText) : 0
            )
        }
        self.archive.cancelledEntryIDs.subtract(entries.map(\.id))
        self.save()
    }

    private func save() {
        guard let fileURL = self.fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self.archive)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DebugLogger.shared.error("Stats archive save failed: \(error.localizedDescription)", source: "StatsArchiveStore")
        }
    }
}
