import Foundation

// 未送信の点を端末のファイルにためて、40件ずつ POST /pub で送る
@MainActor
final class Sender {
    static let shared = Sender()
    private(set) var queue: [Fix] = Files.load(Files.queue, as: [Fix].self) ?? []
    private var sending = false
    var onConfigChanged: ((Config) -> Void)?

    var pending: Int { queue.count }

    func add(_ f: Fix) {
        queue.append(f)
        Files.save(queue, Files.queue)
    }

    private func request(_ path: String) -> URLRequest? {
        guard !Prefs.url.isEmpty, let u = URL(string: Prefs.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 10)
        let token = Data("\(Prefs.user):\(Keychain.password)".utf8).base64EncodedString()
        r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    // 送り終わったらtrue
    @discardableResult
    func flush() async -> Bool {
        if sending { return false }
        sending = true
        defer { sending = false }
        while !queue.isEmpty {
            let batch = Array(queue.prefix(40))
            guard var r = request("/pub") else { Log.w("送信できない（接続の設定が空）"); return false }
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONEncoder().encode(batch)
            do {
                let (data, resp) = try await URLSession.shared.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { Log.w("送信の失敗 \(code)（\(batch.count)件）"); return false }
                queue.removeFirst(batch.count)
                Files.save(queue, Files.queue)
                Prefs.lastSent = Date().timeIntervalSince1970
                Log.w("送信 \(batch.count)件")
                if let v = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["v"] as? String, v != Prefs.config.v {
                    await fetchConfig()
                }
            } catch {
                Log.w("送信の失敗 \(error.localizedDescription)（\(batch.count)件）")
                return false
            }
        }
        return true
    }

    func fetchConfig() async {
        guard let r = request("/config") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { Log.w("設定の取得の失敗"); return }
            let c = try JSONDecoder().decode(Config.self, from: data)
            Prefs.config = c
            Log.w("設定を更新（版 \(c.v)、場所 \(c.places.count)件）")
            onConfigChanged?(c)
        } catch {
            Log.w("設定の取得の失敗 \(error.localizedDescription)")
        }
    }
}
