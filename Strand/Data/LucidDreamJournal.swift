import Foundation

/// What Lucid Dream Mode saw during one sleep session: whether the REM-watch window was reached and when
/// cues fired. Persisted so the morning check-in survives a relaunch.
struct LucidNightRecord: Codable, Equatable {
    let sessionID: String
    let sleepOnset: Int
    var monitored: Bool
    var cueTimes: [Int]
    var lastSeenAt: Int
}

/// One morning answer. `wokeFromCue` is nil on a night with no cues, so uncued nights act as the
/// comparison group for cued ones.
struct LucidCheckIn: Codable, Equatable {
    let sessionID: String
    let sleepOnset: Int
    let cues: Int
    let lucid: Bool
    let wokeFromCue: Bool?
    let dreamRecalled: Bool
    let answeredAt: Int
}

/// Personal results across answered nights.
struct LucidJournalTally: Equatable {
    let nights: Int
    let cuedNights: Int
    let lucidCued: Int
    let uncuedNights: Int
    let lucidUncued: Int
    let wokeFromCue: Int
    let recalled: Int

    init(_ entries: [LucidCheckIn]) {
        let cued = entries.filter { $0.cues > 0 }
        let uncued = entries.filter { $0.cues == 0 }
        nights = entries.count
        cuedNights = cued.count
        lucidCued = cued.filter(\.lucid).count
        uncuedNights = uncued.count
        lucidUncued = uncued.filter(\.lucid).count
        wokeFromCue = cued.filter { $0.wokeFromCue == true }.count
        recalled = entries.filter(\.dreamRecalled).count
    }
}

/// Local-only check-in journal (JSONL beside the event log) plus the in-progress night record.
struct LucidDreamJournal {
    static let fileName = "lucid_dream_journal.jsonl"
    static let nightKey = "lucidDream.nightRecord"
    /// A night is ready for its check-in once nothing has been seen for this long.
    static let checkInDelaySeconds = 20 * 60

    private let directory: URL
    private let defaults: UserDefaults

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    // MARK: Night record

    var night: LucidNightRecord? {
        get {
            defaults.data(forKey: Self.nightKey).flatMap { try? JSONDecoder().decode(LucidNightRecord.self, from: $0) }
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.nightKey)
            } else {
                defaults.removeObject(forKey: Self.nightKey)
            }
        }
    }

    /// Note activity for `sessionID`. A different session replaces an unanswered monitored night only once
    /// it reaches monitoring itself: a nap never gets that far, so the night is not lost to it, but the next
    /// real night does, so one skipped check-in cannot block every later night's record.
    func touch(sessionID: String, sleepOnset: Int, monitored: Bool, now: Int) {
        if var current = night, current.sessionID == sessionID {
            current.monitored = current.monitored || monitored
            current.lastSeenAt = now
            night = current
            return
        }
        if !monitored, let current = night, current.monitored, !isAnswered(current.sessionID) { return }
        night = LucidNightRecord(sessionID: sessionID, sleepOnset: sleepOnset, monitored: monitored,
                                 cueTimes: [], lastSeenAt: now)
    }

    func recordCue(sessionID: String, at time: Int) {
        guard var current = night, current.sessionID == sessionID else { return }
        current.cueTimes.append(time)
        current.lastSeenAt = time
        night = current
    }

    /// The night awaiting a morning answer, if any.
    func pendingCheckIn(now: Int) -> LucidNightRecord? {
        guard let current = night, current.monitored, !isAnswered(current.sessionID),
              now - current.lastSeenAt >= Self.checkInDelaySeconds else { return nil }
        return current
    }

    // MARK: Answers

    func entries() -> [LucidCheckIn] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(LucidCheckIn.self, from: Data($0.utf8)) }
    }

    func isAnswered(_ sessionID: String) -> Bool {
        entries().contains { $0.sessionID == sessionID }
    }

    func answer(_ record: LucidNightRecord, lucid: Bool, wokeFromCue: Bool?, dreamRecalled: Bool, now: Int) {
        let entry = LucidCheckIn(sessionID: record.sessionID, sleepOnset: record.sleepOnset,
                                 cues: record.cueTimes.count, lucid: lucid,
                                 wokeFromCue: record.cueTimes.isEmpty ? nil : wokeFromCue,
                                 dreamRecalled: dreamRecalled, answeredAt: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
