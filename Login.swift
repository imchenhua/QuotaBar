// 添加 / 重新登录账号。
//
// 窗口只在用户点「登录」时存在，关掉即销毁；没有任何后台轮询，
// 登录失败也不会自动重试——ClaudeBar 就是死在「失败即重试」这条路上。

import AppKit
import CryptoKit
import Foundation
import WebKit

@MainActor
final class LoginController: NSObject, NSWindowDelegate {
    static let shared = LoginController()

    private static let clientID = ClaudeOAuth.clientID
    private static let redirectURI = ClaudeOAuth.redirectURI
    private static let scope = ClaudeOAuth.scope

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var timer: Timer?
    private var busy = false
    private var verifier = ""
    private var oauthState = ""
    private var targetAccount: Account?
    private var generation = UUID()
    var isPresenting: Bool { window != nil }

    func present(for account: Account? = nil) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        self.targetAccount = account
        generation = UUID()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 700))

        let label = NSTextField(labelWithString: L("登录后会自动存下这个账号的凭据，以后切换不用再登录"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = label
        container.addSubview(label)

        let cancel = NSButton(title: L("取消"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancel)

        let paste = NSButton(title: L("手动粘贴"), target: self, action: #selector(pasteTapped))
        paste.bezelStyle = .rounded
        paste.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paste)

        let browser = NSButton(title: L("用浏览器登录"), target: self, action: #selector(browserTapped))
        browser.bezelStyle = .rounded
        browser.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(browser)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.translatesAutoresizingMaskIntoConstraints = false
        webView = web
        container.addSubview(web)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            cancel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            paste.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            paste.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: paste.leadingAnchor, constant: -12),
            browser.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            browser.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            web.topAnchor.constraint(equalTo: browser.bottomAnchor, constant: 10),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("添加 Claude 账号")
        window.contentView = container
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        verifier = Self.randomVerifier()
        oauthState = Self.randomVerifier()
        if let url = OAuthPKCE.authorizeURL(verifier: verifier, state: oauthState) {
            web.load(URLRequest(url: url))
        }
        log("登录窗口已打开（OAuth 授权）")

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    @objc private func browserTapped() {
        guard let url = OAuthPKCE.authorizeURL(verifier: verifier, state: oauthState) else { return }
        NSWorkspace.shared.open(url)
        statusLabel?.stringValue = L("请在浏览器完成授权，再点「手动粘贴」输入授权码")
    }

    @objc private func cancelTapped() {
        close()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        busy = false
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        generation = UUID()
        busy = false
        webView?.stopLoading()
        webView = nil
        statusLabel = nil
        targetAccount = nil
        window = nil
        log("登录窗口已关闭")
    }

    private func readSessionKey() async -> String? {
        guard let store = webView?.configuration.websiteDataStore else { return nil }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return cookies.first {
            $0.name == "sessionKey" && ($0.domain == "claude.ai" || $0.domain == ".claude.ai")
        }?.value
    }

    @objc private func pasteTapped() {
        let alert = NSAlert()
        alert.messageText = L("粘贴授权码")
        alert.informativeText = L("把授权页上显示的 code#state 原样贴进来。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "code#state"
        alert.accessoryView = field
        alert.addButton(withTitle: L("确定"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        Task { @MainActor in await self.finish(rawCode: text) }
    }

    // MARK: OAuth PKCE

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8]()
        for _ in 0..<32 { bytes.append(UInt8.random(in: 0...255)) }
        return base64URL(Data(bytes))
    }

    /// 只在授权回调页上找 code#state，其他页面一律不看。
    private func tick() async {
        guard !busy, let web = webView, let host = web.url?.host else { return }
        guard host == "console.anthropic.com" || host == "platform.claude.com" else {
            return
        }
        guard let raw = await scrapeCode() else {
            statusLabel?.stringValue = L("没自动读到授权码，点「手动粘贴」把页面上的 code 贴进来")
            return
        }
        busy = true
        statusLabel?.stringValue = L("已拿到授权码，正在换取凭据…")
        await finish(rawCode: raw)
    }

    private func scrapeCode() async -> String? {
        guard let web = webView else { return nil }
        let script = """
        (function(){
          function pick(text){
            if(!text) return null;
            var m = String(text).match(/([A-Za-z0-9_-]{20,})#([A-Za-z0-9_-]{20,})/);
            return m ? m[1] + '#' + m[2] : null;
          }
          var body = document.body ? document.body.innerText : '';
          var hit = pick(body);
          if (hit) return hit;
          var nodes = document.querySelectorAll('input,textarea,code,pre');
          for (var i = 0; i < nodes.length; i++) {
            var value = nodes[i].value || nodes[i].textContent || '';
            var m = pick(value);
            if (m) return m;
          }
          return null;
        })();
        """
        let result = try? await web.evaluateJavaScript(script)
        return result as? String
    }

    private func finish(rawCode: String) async {
        let attempt = generation
        let parts = rawCode.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            statusLabel?.stringValue = L("授权码格式不对，应该是 code#state")
            busy = false
            return
        }
        guard parts[1] == oauthState else {
            statusLabel?.stringValue = L("授权状态不匹配，请关闭窗口后重新登录")
            busy = false
            return
        }
        timer?.invalidate()
        timer = nil
        let exchanged = await exchange(code: parts[0], state: parts[1])
        guard generation == attempt, window != nil else { return }
        guard let payload = exchanged else {
            statusLabel?.stringValue = L("换取凭据失败，详情看 ~/Library/Logs/QuotaBar")
            busy = false
            return
        }

        guard generation == attempt, window != nil else { return }
        let profileResult: OAuthProfile?
        if let token = accessToken(of: payload) { profileResult = await fetchProfile(token: token) }
        else { profileResult = nil }
        guard generation == attempt, window != nil else { return }
        guard let profile = profileResult,
              let email = profile.account.email?.lowercased(), !email.isEmpty,
              let org = profile.organization?.uuid, !org.isEmpty else {
            statusLabel?.stringValue = L("无法核验 OAuth 账号身份，未保存。请重新登录")
            busy = false; return
        }
        guard generation == attempt, window != nil else { return }
        if let target = targetAccount,
           (target.email?.lowercased() != email || target.org.lowercased() != org.lowercased()) {
            statusLabel?.stringValue = L("登录的是其他账号，未覆盖目标账号。请关闭后重新登录")
            busy = false; return
        }
        var sessionKey = targetAccount?.sessionKey ?? ""
        if let key = await readSessionKey(), let identity = await fetchIdentity(sessionKey: key),
           identity.email_address?.lowercased() == email,
           identity.memberships?.contains(where: { $0.organization.uuid.lowercased() == org.lowercased() }) == true {
            sessionKey = key
        }
        guard generation == attempt, window != nil else { return }
        let fallbackName = email.split(separator: "@").first.map(String.init) ?? email
        let nickname = targetAccount?.name ?? fallbackName
        let account = Account(name: nickname, email: email, org: org, sessionKey: sessionKey)
        guard CredentialStore.store(payload: payload, email: email, for: account),
              Paths.upsert(account) else {
            statusLabel?.stringValue = L("凭据或账号保存失败，原资料保留，请检查日志后重试")
            busy = false; return
        }
        log("登录成功 \(nickname) <\(email)>，凭据已存入槽")

        QuotaStore.shared.didAuthenticate(account)
        QuotaStore.shared.switchNote = "已保存 \(nickname)。需要使用它时再点「切换」"
        close()
    }

    private func exchange(code: String, state: String) async -> String? {
        guard let url = URL(string: ClaudeOAuth.tokenURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let session = oauthSession()

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String,
              let refresh = root["refresh_token"] as? String
        else {
            log("OAuth 换取凭据失败")
            return nil
        }

        let expiresIn = (root["expires_in"] as? Double) ?? 28800
        let scopes = (root["scope"] as? String).map { $0.split(separator: " ").map(String.init) }
            ?? Self.scope.split(separator: " ").map(String.init)
        var oauth: [String: Any] = [
            "accessToken": access,
            "refreshToken": refresh,
            "expiresAt": Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000),
            "scopes": scopes,
            "subscriptionTypeSource": "sign_in",
        ]
        if let account = root["account"] as? [String: Any],
           let subscription = account["subscription_type"] as? String {
            oauth["subscriptionType"] = subscription
        }

        guard let payloadData = try? JSONSerialization.data(
                withJSONObject: ["claudeAiOauth": oauth],
                options: [.sortedKeys]),
              let payload = String(data: payloadData, encoding: .utf8)
        else { return nil }
        return payload
    }
}
