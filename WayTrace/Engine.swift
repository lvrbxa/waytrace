import CoreLocation
import Network
import UIKit

// 測位と状態の切替。設計の正本: ExBrain Vault 30_Projects/2026-11-10_WayTrace.md「アプリ」
@MainActor
final class Engine: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Engine()
    static let names = ["停止", "省電力", "移動"]

    @Published private(set) var state = Prefs.state
    @Published private(set) var pending = 0
    @Published private(set) var lastSent: Date?

    private let lm = CLLocationManager()
    private var session: CLServiceSession?
    private var monitor: CLMonitor?
    private var started = false
    private let path = NWPathMonitor()
    private var conn = "n"
    private var timer: Timer?
    private var recent: [Sample] = []
    private var lastMeasured = Date()
    private var measuring = false
    private var confirming = false
    private var confirmEnd = Date.distantPast
    private var fresh: Set<String> = []
    private var lastEvent: [String: Bool] = [:]
    private var collected: [CLLocation] = []
    private var collectCont: CheckedContinuation<CLLocation?, Never>?
    private var collectAcc: Double = 20
    private var k: Konst { Prefs.config.k }
    private var places: [Place] { Prefs.config.places }

    // 起動時（システムに起こされたときも）に作り直し、保存した状態に戻す
    func start() {
        guard !started else { return }
        started = true
        session = CLServiceSession(authorization: .always)
        lm.delegate = self
        lm.allowsBackgroundLocationUpdates = true
        lm.pausesLocationUpdatesAutomatically = false
        lm.showsBackgroundLocationIndicator = false
        if lm.authorizationStatus == .notDetermined { lm.requestAlwaysAuthorization() }
        UIDevice.current.isBatteryMonitoringEnabled = true
        path.pathUpdateHandler = { [weak self] p in
            let c = p.usesInterfaceType(.wifi) ? "w" : p.status == .satisfied ? "m" : "n"
            Task { @MainActor in self?.conn = c }
        }
        path.start(queue: .main)
        Sender.shared.onConfigChanged = { [weak self] c in Task { await self?.syncCircles(c) } }
        refresh()
        Log.w("起動（状態 \(Engine.names[state])）")
        Task {
            await setupMonitor()
            apply(state, reason: "起動時に戻す")
            if Prefs.config.v.isEmpty { await Sender.shared.fetchConfig() }
        }
    }

    private func refresh() {
        pending = Sender.shared.pending
        lastSent = Prefs.lastSent > 0 ? Date(timeIntervalSince1970: Prefs.lastSent) : nil
    }

    // MARK: 状態

    func apply(_ s: Int, reason: String) {
        if s != state { Log.w("状態を\(Engine.names[s])へ（\(reason)）") }
        state = s
        Prefs.state = s
        timer?.invalidate(); timer = nil
        switch s {
        case 2:
            Task { await removeFollow() }
            lm.stopMonitoringSignificantLocationChanges()
            lm.stopMonitoringVisits()
            coarse()
            startTimer()
            Log.w("1分ごとの測位を開始")
        case 1:
            lm.stopUpdatingLocation()
            lm.startMonitoringSignificantLocationChanges()
            lm.startMonitoringVisits()
        default:
            lm.stopUpdatingLocation()
            lm.stopMonitoringSignificantLocationChanges()
            lm.stopMonitoringVisits()
            Task { await removeFollow() }
        }
    }

    // 画面からの切り替え
    func manual(_ s: Int) async {
        if s == 1, let p = await measureOne("u") {
            apply(1, reason: "手動")
            await setFollow(p.la, p.lo)
        } else {
            apply(s, reason: "手動")
        }
    }

    // 「外出」ショートカット: 呼ばれた時刻で1点送り、移動へ
    func goOut() async {
        let t = Int(Date().timeIntervalSince1970)
        Log.w("外出のショートカット")
        _ = await measureOne("w", at: t)
        apply(2, reason: "外出")
        _ = await withTaskGroup(of: Bool.self) { g in
            g.addTask { await Sender.shared.flush() }
            g.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
            let r = await g.next() ?? false
            g.cancelAll()
            return r
        }
        refresh()
    }

    private func startTimer() {
        lastMeasured = Date()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(k.interval), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func tick() async {
        guard state == 2, !measuring else { return }
        lastMeasured = Date()
        guard let s = await measureOne("m") else { return }
        let now = Int(Date().timeIntervalSince1970)
        switch Logic.nextFromMoving(recent, now: now, k: k, places: places, wifi: conn == "w") {
        case .stop:
            apply(0, reason: "自宅で静止")
        case .power:
            apply(1, reason: "静止")
            if let c = Logic.followCenter(recent, now: now, places: places) { await setFollow(c.0, c.1) }
        case .keep:
            _ = s
        }
    }

    // 移動中にretry_secs点が無ければ、位置更新とタイマーを作り直す
    private func watchdog() {
        guard state == 2, !measuring, Date().timeIntervalSince(lastMeasured) > TimeInterval(k.retry_secs) else { return }
        Log.w("毎分の点が止まっていたので、位置更新とタイマーを作り直す")
        lm.stopUpdatingLocation()
        coarse()
        timer?.invalidate()
        startTimer()
        Task { await tick() }
    }

    // iOSに起こされたとき（停止・省電力）: 2点測って、2点とも円の外なら移動へ
    private func wake(_ g: String, why: String) async {
        guard state != 2 else { return }
        if confirming { Log.w("確認の途中の知らせ（無視）: \(why)"); return }
        if g == "s", Date().timeIntervalSince(confirmEnd) < 60 { return }
        Log.w("起こされた: \(why)")
        confirming = true
        defer { confirming = false; confirmEnd = Date() }
        guard let a = await measureOne(g), let b = await measureOne(g) else { return }
        if Logic.confirmMove(a, b, k: k, places: places) {
            apply(2, reason: "確認の2点が円の外")
        } else if state == 1 {
            await setFollow(b.la, b.lo)
        }
    }

    // MARK: 測位

    private func coarse() {
        if state == 2 {
            lm.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            lm.distanceFilter = 50
            lm.startUpdatingLocation()
        } else {
            lm.stopUpdatingLocation()
        }
    }

    private func collect() async -> CLLocation? {
        collected = []
        collectAcc = k.acc
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.distanceFilter = kCLDistanceFilterNone
        lm.startUpdatingLocation()
        let wait = UInt64(k.wait) * 1_000_000_000
        let loc: CLLocation? = await withCheckedContinuation { c in
            collectCont = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: wait)
                self.finishCollect()
            }
        }
        coarse()
        return loc
    }

    private func finishCollect() {
        guard let c = collectCont else { return }
        collectCont = nil
        c.resume(returning: collected.filter { $0.horizontalAccuracy >= 0 }.min { $0.horizontalAccuracy < $1.horizontalAccuracy })
    }

    // 1点測って送信へ渡す。at: 送る時刻（外出のショートカット）
    private func measureOne(_ g: String, at: Int? = nil) async -> Sample? {
        measuring = true
        defer { measuring = false }
        guard let loc = await collect() else { Log.w("測れなかった（きっかけ \(g)）"); return nil }
        let t = at ?? Int(loc.timestamp.timeIntervalSince1970)
        let lastT = UserDefaults.standard.integer(forKey: "lastFixT")
        let from = Date(timeIntervalSince1970: TimeInterval(lastT > 0 && lastT < t ? lastT : t - 60))
        let to = Date(timeIntervalSince1970: TimeInterval(t))
        async let st = Motion.steps(from: from, to: to)
        async let act = Motion.activities(from: from, to: to)
        let batt = UIDevice.current.batteryLevel
        let fix = Fix(t: t, la: loc.coordinate.latitude, lo: loc.coordinate.longitude, ac: loc.horizontalAccuracy,
                      v: loc.speed >= 0 ? loc.speed * 3.6 : nil, s: state, b: batt >= 0 ? Int(batt * 100) : 0,
                      c: conn, g: g, st: await st, a: await act)
        UserDefaults.standard.set(t, forKey: "lastFixT")
        Sender.shared.add(fix)
        if fix.st == nil || fix.a == nil { Backfill.add(fix, from: from) }
        Log.w("測った点 精度\(Int(fix.ac))m（きっかけ \(g)）歩数 \(fix.st.map(String.init) ?? "取れない")・活動 \(fix.a == nil ? "取れない" : "取れた")")
        let s = Sample(t: t, la: fix.la, lo: fix.lo, ac: fix.ac)
        recent = (recent + [s]).filter { t - $0.t <= 600 }
        Task { await Sender.shared.flush(); refresh() }
        return s
    }

    // MARK: 円の見張り（CLMonitor）

    private func setupMonitor() async {
        let m = await CLMonitor("waytrace")
        monitor = m
        Task {
            do {
                for try await e in await m.events { await handle(e) }
            } catch {
                Log.w("円の見張りが止まった \(error.localizedDescription)")
            }
        }
        await syncCircles(Prefs.config)
    }

    private func handle(_ e: CLMonitor.Event) async {
        let id = e.identifier
        let inside: Bool
        switch e.state {
        case .satisfied: inside = true
        case .unsatisfied: inside = false
        default: return
        }
        if fresh.remove(id) != nil { lastEvent[id] = inside; return } // 置いた直後の知らせ
        if lastEvent[id] == inside { return } // 重複して届いた知らせ
        lastEvent[id] = inside
        let name = id == "follow" ? "追いかけの円" : places.first { "p\($0.id)" == id }?.name ?? id
        await wake(id == "follow" ? "f" : "r", why: "\(name)を\(inside ? "入" : "出")")
    }

    func syncCircles(_ c: Config) async {
        guard let m = monitor else { return }
        if c.places.count > 19 { Log.w("場所が19件を超えたので、円を更新しない"); return }
        var cur = Prefs.circles
        let want = Dictionary(uniqueKeysWithValues: c.places.map { ("p\($0.id)", "\($0.la),\($0.lo),\($0.r)") })
        for id in cur.keys where id != "follow" && want[id] == nil {
            await m.remove(id); cur[id] = nil
        }
        for p in c.places {
            let id = "p\(p.id)"
            guard cur[id] != want[id] else { continue }
            await m.add(CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: p.la, longitude: p.lo), radius: p.r), identifier: id)
            fresh.insert(id)
            cur[id] = want[id]
        }
        Prefs.circles = cur
    }

    private func setFollow(_ la: Double, _ lo: Double) async {
        guard let m = monitor else { return }
        await m.remove("follow")
        await m.add(CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: la, longitude: lo), radius: k.follow_m), identifier: "follow")
        fresh.insert("follow")
        lastEvent["follow"] = nil
        Prefs.circles["follow"] = "\(la),\(lo),\(k.follow_m)"
    }

    private func removeFollow() async {
        guard let m = monitor, Prefs.circles["follow"] != nil else { return }
        await m.remove("follow")
        Prefs.circles["follow"] = nil
    }

    // MARK: 前面に出たとき

    private func insideFollow(_ l: CLLocation) -> Bool {
        let v = (Prefs.circles["follow"] ?? "").split(separator: ",").compactMap { Double($0) }
        guard v.count == 3 else { return false }
        return Logic.dist(l.coordinate.latitude, l.coordinate.longitude, v[0], v[1]) <= v[2]
    }

    func foreground() async {
        await Backfill.run()
        await Sender.shared.flush()
        refresh()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if collectCont != nil {
                collected += locations
                if locations.contains(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= collectAcc }) { finishCollect() }
                return
            }
            if state == 2 { watchdog(); return }
            if state == 1 {
                // 届いた位置が追いかけの円の中なら、動いていないので無視する
                if let l = locations.last, insideFollow(l) { Log.w("大きな移動の知らせ（追いかけの円の中、無視）"); return }
                Task { await wake("s", why: "大きな移動") }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        MainActor.assumeIsolated {
            if state == 1 { Task { await wake("v", why: "訪問") } }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in Log.w("位置の失敗 \(msg)") }
    }
}

// 歩数・活動が取れなかった点を、前面に出たときに照会し直して同じtで送り直す
enum Backfill {
    struct Item: Codable { var fix: Fix; var from: Double }

    @MainActor static func add(_ f: Fix, from: Date) {
        var list = Files.load(Files.backfill, as: [Item].self) ?? []
        list.append(Item(fix: f, from: from.timeIntervalSince1970))
        Files.save(list, Files.backfill)
    }

    @MainActor static func run() async {
        let now = Date().timeIntervalSince1970
        var keep: [Item] = []
        for var it in (Files.load(Files.backfill, as: [Item].self) ?? []) where now - Double(it.fix.t) < 7 * 86400 {
            let from = Date(timeIntervalSince1970: it.from), to = Date(timeIntervalSince1970: TimeInterval(it.fix.t))
            if it.fix.st == nil { it.fix.st = await Motion.steps(from: from, to: to) }
            if it.fix.a == nil { it.fix.a = await Motion.activities(from: from, to: to) }
            if it.fix.st != nil || it.fix.a != nil { Sender.shared.add(it.fix) }
            if it.fix.st == nil || it.fix.a == nil { keep.append(it) }
        }
        Files.save(keep, Files.backfill)
    }
}
