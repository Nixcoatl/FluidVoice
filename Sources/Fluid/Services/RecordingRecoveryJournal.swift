import Foundation

/// Streams the audio of the current recording to disk every few seconds, so a crash or
/// unexpected quit never loses a dictation. On the next launch, leftover journals are
/// transcribed into History. Raw 16 kHz mono Float32, deleted shortly after a normal stop.
@MainActor
final class RecordingRecoveryJournal {
    static let shared = RecordingRecoveryJournal()

    private static let sampleRate = 16_000
    private static let flushIntervalNanoseconds: UInt64 = 3_000_000_000
    /// Grace period after a stop before the journal is deleted, covering the final transcription.
    private static let deleteDelayNanoseconds: UInt64 = 20_000_000_000
    /// Recordings shorter than this are not worth recovering.
    private static let minimumRecoverableSeconds: Double = 3

    private struct Session {
        let url: URL
        let handle: FileHandle
        var writtenSamples: Int
    }

    private var session: Session?
    private var flushTask: Task<Void, Never>?
    private var isRecovering = false

    private init() {}

    private var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent("RecordingRecovery", isDirectory: true)
    }

    // MARK: - Recording

    func begin(asr: ASRService) {
        guard self.session == nil, let directory = self.directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970)).f32")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            self.session = Session(url: url, handle: handle, writtenSamples: 0)
        } catch {
            DebugLogger.shared.warning("Recovery journal could not start: \(error.localizedDescription)", source: "RecordingRecovery")
            return
        }

        self.flushTask = Task { @MainActor [weak self, weak asr] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.flushIntervalNanoseconds)
                guard !Task.isCancelled, let self, let asr else { return }
                self.flush(asr: asr)
            }
        }
    }

    func end() {
        self.flushTask?.cancel()
        self.flushTask = nil
        guard let session = self.session else { return }
        self.session = nil
        try? session.handle.close()
        let url = session.url
        Task {
            try? await Task.sleep(nanoseconds: Self.deleteDelayNanoseconds)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func flush(asr: ASRService) {
        guard var session = self.session else { return }
        let available = asr.recoveryJournalSampleCount
        guard available > session.writtenSamples else { return }
        let samples = asr.recoveryJournalSamples(from: session.writtenSamples, count: available - session.writtenSamples)
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try session.handle.write(contentsOf: data)
            session.writtenSamples += samples.count
            self.session = session
        } catch {
            DebugLogger.shared.warning("Recovery journal write failed: \(error.localizedDescription)", source: "RecordingRecovery")
        }
    }

    // MARK: - Recovery on launch

    /// Transcribes journals left behind by a crash or forced quit into History.
    func recoverLeftoverRecordings(using services: AppServices) {
        guard !self.isRecovering, let directory = self.directory else { return }
        let leftovers = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "f32" && $0 != self.session?.url }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !leftovers.isEmpty else { return }

        self.isRecovering = true
        Task { @MainActor in
            defer { self.isRecovering = false }
            for journal in leftovers {
                await self.recover(journal, using: services)
            }
        }
    }

    private func recover(_ journal: URL, using services: AppServices) async {
        guard let data = try? Data(contentsOf: journal) else { return }
        let samples: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let seconds = Double(samples.count) / Double(Self.sampleRate)
        guard seconds >= Self.minimumRecoverableSeconds else {
            try? FileManager.default.removeItem(at: journal)
            return
        }

        let wavURL = journal.deletingPathExtension().appendingPathExtension("wav")
        do {
            try Self.writeWAV(samples: samples, sampleRate: Self.sampleRate, to: wavURL)
        } catch {
            DebugLogger.shared.warning("Recovery WAV write failed: \(error.localizedDescription)", source: "RecordingRecovery")
            return
        }

        // The ASR engine may be busy (e.g. the user is already dictating); retry for a while.
        for attempt in 0..<20 {
            do {
                let result = try await services.fileTranscriptionService.transcribeFile(wavURL)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let startedAt = Self.startDate(of: journal) ?? Date()
                    TranscriptionHistoryStore.shared.addEntry(
                        timestamp: startedAt,
                        rawText: text,
                        processedText: ASRService.applySmartParagraphs(ASRService.applyNumberFormatting(text)),
                        appName: "FluidVoice",
                        windowTitle: "Recovered after unexpected quit",
                        wasAIProcessed: false
                    )
                    NotificationService.showRecoveredDictation(minutes: max(1, Int((seconds / 60).rounded())))
                    DebugLogger.shared.info("Recovered dictation (\(Int(seconds))s, chars: \(text.count))", source: "RecordingRecovery")
                }
                try? FileManager.default.removeItem(at: journal)
                try? FileManager.default.removeItem(at: wavURL)
                return
            } catch {
                DebugLogger.shared.info(
                    "Recovery transcription attempt \(attempt + 1) failed: \(error.localizedDescription)",
                    source: "RecordingRecovery"
                )
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private static func startDate(of journal: URL) -> Date? {
        let stem = journal.deletingPathExtension().lastPathComponent
        guard let seconds = Double(stem.replacingOccurrences(of: "recording-", with: "")) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 16-bit PCM mono WAV.
    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(le32(UInt32(36 + pcm.count)))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(le32(16))
        wav.append(le16(1)) // PCM
        wav.append(le16(1)) // mono
        wav.append(le32(UInt32(sampleRate)))
        wav.append(le32(UInt32(sampleRate * 2)))
        wav.append(le16(2))
        wav.append(le16(16))
        wav.append(contentsOf: Array("data".utf8))
        wav.append(le32(UInt32(pcm.count)))
        wav.append(pcm)
        try wav.write(to: url, options: .atomic)
    }
}
