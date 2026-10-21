import Foundation

/// One structured Lucid Dream Mode event. Optional fields keep one backward-compatible JSONL shape
/// across state transitions, cues, arousal observations, and hardware failures.
struct LucidDreamLogEntry: Codable {
    let timestamp: Int
    let event: String
    let sleepSessionID: String?
    let enabled: Bool
    let sleepOnset: Int?
    let monitoringStart: Int?
    let suspectedREMOnset: Int?
    let stableREMTime: Int?
    let supportingState: String
    let vibrationTimestamp: Int?
    let cueNumber: Int?
    let selectedHapticPattern: String?
    let heartRateBeforeCue: Int?
    let heartRateAfterCue: Int?
    let movementBeforeCue: Double?
    let movementAfterCue: Double?
    let sleepStageBeforeCue: String?
    let sleepStageAfterCue: String?
    let probableArousal: Bool
    let stopReason: String?
    let remEpisodeEnd: Int?
    let hapticError: String?
}

/// Small bounded local JSONL log, following NOOP's existing Application Support archive convention.
struct LucidDreamEventLog {
    static let fileName = "lucid_dream_events.jsonl"
    static let maxBytes = 2 * 1024 * 1024

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appID = Bundle.main.bundleIdentifier ?? "com.noopapp.noop"
            self.directory = base.appendingPathComponent(appID, isDirectory: true)
        }
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func append(_ entry: LucidDreamLogEntry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            trimIfNeeded(forIncomingBytes: data.count)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Logging must never interfere with sleep monitoring or BLE operation.
        }
    }

    private func trimIfNeeded(forIncomingBytes incoming: Int) {
        let existing = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard existing + incoming > Self.maxBytes,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var kept: [Substring] = []
        var bytes = incoming
        for line in lines.reversed() {
            let lineBytes = line.utf8.count + 1
            if bytes + lineBytes > Self.maxBytes / 2 { break }
            kept.append(line)
            bytes += lineBytes
        }
        let compact = kept.reversed().map(String.init).joined(separator: "\n")
        try? (compact.isEmpty ? "" : compact + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
