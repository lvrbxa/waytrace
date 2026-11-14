import Foundation
import Security

// 送る点（POST /pub の1件。項目名はWorkerと同じ短い名前）
struct Fix: Codable, Equatable {
    var t: Int
    var la: Double
    var lo: Double
    var ac: Double
    var v: Double?
    var s: Int
    var b: Int
    var c: String
    var g: String
    var st: Int?
    var a: [Int]?

    func encode(to encoder: Encoder) throws {
        var e = encoder.container(keyedBy: CodingKeys.self)
        try e.encode(t, forKey: .t); try e.encode(la, forKey: .la); try e.encode(lo, forKey: .lo)
        try e.encode(ac, forKey: .ac); try e.encodeIfPresent(v, forKey: .v)
        try e.encode(s, forKey: .s); try e.encode(b, forKey: .b); try e.encode(c, forKey: .c); try e.encode(g, forKey: .g)
        try e.encode(st, forKey: .st); try e.encode(a, forKey: .a) // 取れなかったときはnullを送る
    }
}

enum Files {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let queue = dir.appendingPathComponent("queue.json")
    static let backfill = dir.appendingPathComponent("backfill.json")
    static let log = dir.appendingPathComponent("log.txt")

    static func load<T: Decodable>(_ url: URL, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    static func save<T: Encodable>(_ v: T, _ url: URL) {
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
}

enum Log {
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "MM/dd HH:mm:ss"; return f
    }()
    static func w(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: Files.log) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: Files.log)
        }
        if let a = try? FileManager.default.attributesOfItem(atPath: Files.log.path), let n = a[.size] as? Int, n > 2_000_000,
           let d = try? Data(contentsOf: Files.log) {
            try? d.suffix(1_000_000).write(to: Files.log)
        }
    }
    static func clear() {
        try? Data().write(to: Files.log)
        w("ログを消去")
    }
}

enum Prefs {
    static let d = UserDefaults.standard
    static var url: String { get { d.string(forKey: "url") ?? "" } set { d.set(newValue, forKey: "url") } }
    static var user: String { get { d.string(forKey: "user") ?? "" } set { d.set(newValue, forKey: "user") } }
    static var state: Int { get { d.integer(forKey: "state") } set { d.set(newValue, forKey: "state") } }
    static var lastSent: Double { get { d.double(forKey: "lastSent") } set { d.set(newValue, forKey: "lastSent") } }
    static var config: Config {
        get { (d.data(forKey: "config")).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config() }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "config") }
    }
    // 置いた円（id→"緯度,経度,半径"）
    static var circles: [String: String] {
        get { d.dictionary(forKey: "circles") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "circles") }
    }
}

enum Keychain {
    private static let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "waytrace", kSecAttrAccount as String: "password"]
    static var password: String {
        get {
            var r: AnyObject?
            var query = q; query[kSecReturnData as String] = true
            guard SecItemCopyMatching(query as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        set {
            SecItemDelete(q as CFDictionary)
            var add = q
            add[kSecValueData as String] = newValue.data(using: .utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
