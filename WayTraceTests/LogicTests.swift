import XCTest
@testable import WayTrace

// 架空の場所（座標は試験用）。東へxメートルの点を作る
private let lat0 = 33.0, lon0 = 131.0
private func at(_ x: Double) -> (Double, Double) { (lat0, lon0 + x / (111320 * cos(33 * .pi / 180))) }
private func S(_ t: Int, _ x: Double, ac: Double = 10) -> Sample { let p = at(x); return Sample(t: t, la: p.0, lo: p.1, ac: ac) }
private let home = { () -> Place in let p = at(0); return Place(id: 1, name: "自宅", la: p.0, lo: p.1, r: 45, stop: true) }()
private let shop = { () -> Place in let p = at(1000); return Place(id: 2, name: "店", la: p.0, lo: p.1, r: 30, stop: false) }()
private let k = Konst()

final class LogicTests: XCTestCase {
    func testStill() {
        let pts = [S(0, 500), S(60, 505), S(120, 510), S(180, 500)]
        XCTAssertTrue(Logic.isStill(pts, now: 200, k: k))
        XCTAssertFalse(Logic.isStill(Array(pts.prefix(3)), now: 200, k: k), "3点では足りない")
        XCTAssertFalse(Logic.isStill(pts + [S(240, 600)], now: 250, k: k), "最新の点から50mより遠い点がある")
        XCTAssertFalse(Logic.isStill(pts.map { Sample(t: $0.t, la: $0.la, lo: $0.lo, ac: 30) }, now: 200, k: k), "精度20mより悪い点は数えない")
    }

    func testNextFromMoving() {
        let atHome = [S(0, 0), S(60, 5), S(120, 0), S(180, 5)]
        XCTAssertEqual(Logic.nextFromMoving(atHome, now: 200, k: k, places: [home, shop], wifi: true), .stop)
        XCTAssertEqual(Logic.nextFromMoving(atHome, now: 200, k: k, places: [home, shop], wifi: false), .power, "Wi-Fiが無ければ停止にしない")
        let atShop = [S(0, 1000), S(60, 1005), S(120, 1000), S(180, 1005)]
        XCTAssertEqual(Logic.nextFromMoving(atShop, now: 200, k: k, places: [home, shop], wifi: true), .power, "自宅以外は停止にしない")
        XCTAssertEqual(Logic.nextFromMoving([S(0, 0), S(60, 300)], now: 100, k: k, places: [home], wifi: true), .keep)
    }

    func testFollowCenter() {
        let inShop = [S(0, 990), S(60, 1000)]
        let c = Logic.followCenter(inShop, now: 60, places: [shop])!
        XCTAssertEqual(c.1, inShop[1].lo, accuracy: 1e-9, "円の中なら最新の点")
        let out = [S(0, 500), S(60, 510)]
        let m = Logic.followCenter(out, now: 60, places: [shop])!
        XCTAssertEqual(m.1, (out[0].lo + out[1].lo) / 2, accuracy: 1e-9, "円の外なら平均")
    }

    func testConfirmMove() {
        XCTAssertTrue(Logic.confirmMove(S(0, 500), S(10, 520), k: k, places: [home, shop]))
        XCTAssertFalse(Logic.confirmMove(S(0, 500), S(10, 520, ac: 40), k: k, places: [home, shop]), "精度が悪い")
        XCTAssertFalse(Logic.confirmMove(S(0, 500), S(10, 10), k: k, places: [home, shop]), "円の中")
    }

    func testActivitySeconds() {
        let base = Date(timeIntervalSince1970: 1000)
        let list: [(Date, Int)] = [(base.addingTimeInterval(-100), 0), (base.addingTimeInterval(30), 1), (base.addingTimeInterval(50), 3)]
        XCTAssertEqual(Logic.activitySeconds(list, from: base, to: base.addingTimeInterval(60)), [30, 20, 0, 10, 0, 0])
    }

    func testFixSendsNullForMissingSteps() throws {
        let f = Fix(t: 1, la: 1, lo: 2, ac: 5, v: nil, s: 2, b: 80, c: "w", g: "m", st: nil, a: nil)
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as! [String: Any]
        XCTAssertTrue(o["st"] is NSNull)
        XCTAssertTrue(o["a"] is NSNull)
        XCTAssertNil(o["v"], "速さが無ければ省く")
    }
}
