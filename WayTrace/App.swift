import AppIntents
import SwiftUI
import WebKit

@main
struct WayTraceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(Engine.shared)
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await Engine.shared.foreground() } }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let i = Bundle.main.infoDictionary
        Log.w("WayTrace starting \(i?["CFBundleShortVersionString"] as? String ?? "?").\(i?["CFBundleVersion"] as? String ?? "?")")
        MainActor.assumeIsolated { Engine.shared.start() }
        return true
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            StatusView().tabItem { Label("状態", systemImage: "location") }
            MapTab().tabItem { Label("地図", systemImage: "map") }
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var engine: Engine
    @State private var url = Prefs.url
    @State private var user = Prefs.user
    @State private var password = Keychain.password
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("今") {
                    LabeledContent("状態", value: Engine.names[engine.state])
                    LabeledContent("最後に送った時刻", value: engine.lastSent.map { $0.formatted(date: .omitted, time: .standard) } ?? "まだ")
                    LabeledContent("未送信", value: "\(engine.pending)件")
                }
                Section("状態の切り替え") {
                    ForEach(0..<3) { s in
                        Button(Engine.names[s]) { Task { await engine.manual(s) } }.disabled(engine.state == s)
                    }
                }
                Section("ログ") {
                    ShareLink("ログを書き出す", item: Files.log)
                    Button("ログを消去", role: .destructive) { confirmClear = true }
                        .confirmationDialog("消去しますか", isPresented: $confirmClear) {
                            Button("消去", role: .destructive) { Log.clear() }
                        }
                }
                Section("接続の設定") {
                    TextField("URL", text: $url).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("ID", text: $user).textInputAutocapitalization(.never)
                    SecureField("パスワード", text: $password)
                    Button("保存して設定を取り直す") {
                        Prefs.url = url; Prefs.user = user; Keychain.password = password
                        Task { await Sender.shared.fetchConfig() }
                    }
                }
            }
            .navigationTitle("WayTrace")
        }
    }
}

struct MapTab: View {
    @State private var reload = 0
    var body: some View {
        NavigationStack {
            WebMap(reload: reload)
                .ignoresSafeArea(edges: .bottom)
                .toolbar { Button("更新") { reload += 1 } }
                .navigationTitle("地図")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct WebMap: UIViewRepresentable {
    var reload: Int

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown = -1
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic, challenge.previousFailureCount < 2 else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: Prefs.user, password: Keychain.password, persistence: .forSession))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.navigationDelegate = context.coordinator
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.shown != reload else { return }
        context.coordinator.shown = reload
        guard let u = URL(string: Prefs.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/map") else { return }
        var r = URLRequest(url: u)
        let token = Data("\(Prefs.user):\(Keychain.password)".utf8).base64EncodedString()
        r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        v.load(r)
    }
}

// 「外出」ショートカット（画面を開かない）
struct GoOutIntent: AppIntent {
    static let title: LocalizedStringResource = "外出"
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Engine.shared.start()
        await Engine.shared.goOut()
        return .result()
    }
}

struct WayTraceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GoOutIntent(), phrases: ["\(.applicationName)で外出"], shortTitle: "外出", systemImageName: "figure.walk")
    }
}
