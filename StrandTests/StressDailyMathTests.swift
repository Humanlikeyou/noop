import XCTest
import WhoopStore
@testable import Strand

/// Daily Stress math (Lucid fork, Refs #471): log-domain HRV, averaged terms, a minimum history and
/// floored σ, and trend days scored against their OWN trailing window.
final class StressDailyMathTests: XCTestCase {

    private func day(_ i: Int, rhr: Int?, hrv: Double?) -> DailyMetric {
        let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: i,
                                                         to: Date(timeIntervalSince1970: 1_780_000_000))!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return DailyMetric(day: f.string(from: date), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                           remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                           recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testTooLittleHistoryDoesNotScore() {
        // Six prior days is below `minBaselineDays`, so there is no derived score yet.
        let days = (0..<6).map { day($0, rhr: 55, hrv: 60) } + [day(6, rhr: 60, hrv: 40)]
        XCTAssertNil(StressModel(days: days, stored: []))
    }

    func testTightBaselineDoesNotSaturateOnAOneBeatWobble() {
        // A perfectly flat baseline used to make σ ≈ 0, so a 1 bpm rise pinned the score at 3.
        let days = (0..<30).map { day($0, rhr: 55, hrv: 60) } + [day(30, rhr: 56, hrv: 60)]
        let model = StressModel(days: days, stored: [])
        XCTAssertNotNil(model)
        XCTAssertEqual(model!.band, .medium, "a 1 bpm wobble must not read HIGH")
    }

    func testAveragedTermsKeepAModestDayOutOfHigh() {
        // RHR +0.5σ and HRV -0.5σ used to sum to raw 1.0 (2.19, HIGH). Averaged, it is raw 0.5.
        let b = StressMath.DailyBaseline(rhr: .init(mean: 55, sd: 4),
                                         lnHRV: .init(mean: log(60), sd: 0.2), hrvMeanMs: 60)
        let s = StressMath.score(rhrToday: 57, hrvToday: exp(log(60) - 0.1), baseline: b)!
        XCTAssertEqual(s, StressMath.squash(0.5), accuracy: 1e-9)
        XCTAssertEqual(StressBand(score: s), .medium)
    }

    func testTrendDayKeepsItsOwnScoreWhenLaterHistoryChanges() {
        // A high-RHR day scored against its own past must not be re-graded when a later block of
        // elevated days moves the CURRENT baseline.
        let early = (0..<30).map { day($0, rhr: 55 + ($0 % 3), hrv: 60) } + [day(30, rhr: 64, hrv: 60)]
        let later = early + (31..<60).map { day($0, rhr: 64 + ($0 % 3), hrv: 60) }
        let a = StressModel(days: early, stored: [])!.fullTrend.last!
        let b = StressModel(days: later, stored: [])!.fullTrend.first { $0.date == a.date }
        XCTAssertNotNil(b)
        XCTAssertEqual(a.value, b!.value, accuracy: 1e-9)
        XCTAssertEqual(StressBand(score: a.value), .high, "a +8 bpm day over its own past reads HIGH")
    }
}
