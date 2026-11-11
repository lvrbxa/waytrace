import Foundation

// 位置に依らない判定（単体試験の対象）。設計の正本: ExBrain Vault 30_Projects/2026-11-10_WayTrace.md「状態と切替」

struct Sample: Codable, Equatable {
    var t: Int
    var la: Double
    var lo: Double
    var ac: Double
}

struct Place: Codable, Equatable {
    var id: Int
    var name: String
    var la: Double
    var lo: Double
    var r: Double
    var stop: Bool
}

struct Konst: Codable, Equatable {
    var interval: Int = 60
    var acc: Double = 20
    var wait: Int = 10
    var still_secs: Int = 300
    var still_n: Int = 4
    var still_m: Double = 50
    var follow_m: Double = 20
    var retry_secs: Int = 120
}

struct Config: Codable, Equatable {
    var v: String = ""
    var places: [Place] = []
    var k: Konst = Konst()
}

enum Logic {
    static func dist(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        let rad = { (x: Double) in x * .pi / 180 }
        let p1 = rad(a), p2 = rad(c)
        let h = pow(sin((p2 - p1) / 2), 2) + cos(p1) * cos(p2) * pow(sin(rad(d - b) / 2), 2)
        return 2 * 6371000 * asin(sqrt(h))
    }

    static func inside(_ s: Sample, _ p: Place) -> Bool { dist(s.la, s.lo, p.la, p.lo) <= p.r }

    static func insideAny(_ s: Sample, _ places: [Place]) -> Place? { places.first { inside(s, $0) } }

    // 直近still_secsの精度acc以内の点がstill_n点以上あり、すべて最新の点からstill_m以内
    static func isStill(_ recent: [Sample], now: Int, k: Konst) -> Bool {
        let good = recent.filter { now - $0.t <= k.still_secs && $0.ac <= k.acc }
        guard good.count >= k.still_n, let last = good.max(by: { $0.t < $1.t }) else { return false }
        return good.allSatisfy { dist($0.la, $0.lo, last.la, last.lo) <= k.still_m }
    }

    enum Next: Equatable { case keep, power, stop }

    // 移動中の点ごとに、次の状態を決める
    static func nextFromMoving(_ recent: [Sample], now: Int, k: Konst, places: [Place], wifi: Bool) -> Next {
        guard isStill(recent, now: now, k: k), let last = recent.max(by: { $0.t < $1.t }) else { return .keep }
        if wifi, let p = insideAny(last, places), p.stop { return .stop }
        return .power
    }

    // 追いかけの円の中心: 最新の点が場所の円の中ならその点、外なら直近240秒の点の平均
    static func followCenter(_ recent: [Sample], now: Int, places: [Place]) -> (Double, Double)? {
        guard let last = recent.max(by: { $0.t < $1.t }) else { return nil }
        if insideAny(last, places) != nil { return (last.la, last.lo) }
        let w = recent.filter { now - $0.t <= 240 }
        guard !w.isEmpty else { return (last.la, last.lo) }
        return (w.map(\.la).reduce(0, +) / Double(w.count), w.map(\.lo).reduce(0, +) / Double(w.count))
    }

    // 起こされたときの確認: 2点とも精度acc以内で、どの場所の円の外でもあれば移動へ
    static func confirmMove(_ a: Sample, _ b: Sample, k: Konst, places: [Place]) -> Bool {
        [a, b].allSatisfy { $0.ac <= k.acc && insideAny($0, places) == nil }
    }

    // 活動の履歴（開始時刻と種類の列）を、[静止・歩行・走る・車・自転車・不明]の秒数にする
    static func activitySeconds(_ list: [(Date, Int)], from: Date, to: Date) -> [Int] {
        var out = [0, 0, 0, 0, 0, 0]
        let sorted = list.sorted { $0.0 < $1.0 }
        for (i, item) in sorted.enumerated() {
            let s = max(item.0, from)
            let e = min(i + 1 < sorted.count ? sorted[i + 1].0 : to, to)
            if e > s { out[item.1] += Int(e.timeIntervalSince(s).rounded()) }
        }
        return out
    }
}
