import Foundation

/*
    Claude keeps a history of its own plan usage measurements in each profile, at
        <profile>/plan-usage-history.json
        { "version": 2, "samples": [ { "t": <ms>, "org": "<uuid>", "u": { "fh": 62, "sd": 30, "xu": 0 } } ] }
    fh is the 5-hour (session) limit, sd the weekly limit, xu extra usage, all in percent.
    Claude writes a sample at most every 4.5 minutes while it is running and polling, and
    keeps 30 days. Reading it needs no credentials and asks Anthropic nothing; the price is
    that a measurement is only as fresh as the last time that account's Claude ran.
*/

public struct PlanUsage: Equatable {
    public let measuredAt: Date
    /// 5-hour limit, percent used.
    public let session: Int?
    /// Weekly limit (all models), percent used.
    public let weekly: Int?

    public init(measuredAt: Date, session: Int?, weekly: Int?) {
        self.measuredAt = measuredAt
        self.session = session
        self.weekly = weekly
    }

    /// A 5-hour window ends within 5 hours of its start, so an older measurement says
    /// nothing about now.
    public func isCurrent(at now: Date) -> Bool {
        now.timeIntervalSince(measuredAt) < 5 * 3600
    }

    public func session(at now: Date) -> Int? {
        isCurrent(at: now) ? session : nil
    }

    public func weekly(at now: Date) -> Int? {
        now.timeIntervalSince(measuredAt) < 7 * 86400 ? weekly : nil
    }

    /// How old the measurement is, short enough to sit under the meter: "now", "12m ago",
    /// "3h ago", "4d ago" (Turkish: "şimdi", "12 dk önce", "3 sa önce", "4 gün önce").
    public func age(at now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(measuredAt)) / 60)
        if minutes < 1 { return L("now", "şimdi") }
        if minutes < 60 { return L("\(minutes)m ago", "\(minutes) dk önce") }
        let hours = minutes / 60
        if hours < 48 { return L("\(hours)h ago", "\(hours) sa önce") }
        return L("\(hours / 24)d ago", "\(hours / 24) gün önce")
    }

    public static func latest(profileDir: URL) -> PlanUsage? {
        FileCache.value(profileDir.appendingPathComponent("plan-usage-history.json"), parse: latest(historyData:))
    }

    /// The newest sample, from version 2 ({t, org, u: {fh, sd}}) or version 1 ({t, fh, sd})
    /// files. nil for anything else: the format is Claude's and may change.
    public static func latest(historyData: Data) -> PlanUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: historyData)) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        let newest = samples.max { ((($0["t"] as? NSNumber)?.doubleValue) ?? 0) < ((($1["t"] as? NSNumber)?.doubleValue) ?? 0) }
        guard let sample = newest, let t = (sample["t"] as? NSNumber)?.doubleValue, t > 0 else { return nil }
        let values = (sample["u"] as? [String: Any]) ?? sample
        func percent(_ key: String) -> Int? {
            guard let n = values[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
            return Int(min(max(n.doubleValue, 0), 100_000).rounded())
        }
        let usage = PlanUsage(measuredAt: Date(timeIntervalSince1970: t / 1000), session: percent("fh"), weekly: percent("sd"))
        return usage.session == nil && usage.weekly == nil ? nil : usage
    }
}
