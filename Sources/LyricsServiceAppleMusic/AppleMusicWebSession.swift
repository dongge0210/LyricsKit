import Foundation
import WebKit
import os
import LyricsService

/// A persistent `music.apple.com` session that calls the private amp-api from
/// *inside* the page.
///
/// Unlike a native `URLSession`, amp-api requires the browser's session cookies
/// and Apple's developer token (extracted from the web player's `MusicKit`
/// instance). This class hosts a single background `WKWebView` that never
/// appears on screen.
///
/// The user **never signs in** through the web view. Instead the host app
/// injects a `media-user-token` cookie (pasted by the user) before the first
/// load, and `MusicKit` on the page picks it up as if the user were already
/// authenticated.
///
/// No MusicKit entitlement, no `MusicAuthorization`, no registration with Apple
/// required.
@available(macOS 12.0, *)
@MainActor
public final class AppleMusicWebSession: NSObject {

    /// Shared session, used by the Apple Music providers.
    public static let shared = AppleMusicWebSession()

    /// The web view hosting `music.apple.com`. Kept off-screen; never added to
    /// a window.
    public let webView: WKWebView

    private var configuredToken: String?
    private var didStartLoading = false
    private var pageLoadContinuation: CheckedContinuation<Void, Never>?

    public override init() {
        let configuration = WKWebViewConfiguration()
        // The default website data store is persistent: cookies survive
        // relaunches so the token only needs to be injected once.
        webView = WKWebView(frame: .zero, configuration: configuration)
        // music.apple.com only serves the full web player to a desktop UA.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Token Configuration

    /// Inject the user's `media-user-token` as a `.apple.com` cookie, navigate
    /// to `music.apple.com`, and wait until the page (and its MusicKit runtime)
    /// are ready before returning.
    ///
    /// Call once on startup and whenever the user changes the token in
    /// preferences. Safe to call repeatedly — the cookie store is idempotent.
    public func configure(mediaUserToken: String) async {
        let previous = configuredToken
        configuredToken = mediaUserToken

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        guard let cookie = HTTPCookie(properties: [
            .domain: ".apple.com",
            .path: "/",
            .name: "media-user-token",
            .value: mediaUserToken,
            .secure: true,
            .expires: Date.distantFuture,
        ]) else {
            Logger.AppleMusic.warning("Failed to create HTTPCookie — check token value")
            return
        }

        await cookieStore.setCookie(cookie)

        // HTTPCookie value getter may URL-decode '+' → space on read-back.
        // The real test is what the browser actually sees. Verify from JS.
        if let verified = await cookieStore.allCookies()
            .first(where: { $0.name == "media-user-token" }) {
            Logger.AppleMusic.debug("""
                HTTPCookie.value (Swift round-trip): \(verified.value.count) chars
                  prefix: \(String(verified.value.prefix(20)))...
                """)
        }

        // Reload the page if the token changed so MusicKit re-reads the cookie.
        if previous != mediaUserToken || !didStartLoading {
            if didStartLoading {
                webView.reload()
            } else {
                startLoading()
            }
            // Block until the page (and MusicKit) are ready.
            await waitForPageLoad()

            // Verify the cookie from the JS side (what the browser actually sees).
            let jsCookie: String? = try? await webView.callAsyncJavaScript(
                """
                document.cookie.split(';')
                    .map(c => c.trim())
                    .find(c => c.startsWith('media-user-token='))
                    ?.replace('media-user-token=', '') || ''
                """,
                arguments: [:], in: nil, contentWorld: .page
            ) as? String
            if let jsVal = jsCookie, !jsVal.isEmpty {
                let match = jsVal == mediaUserToken
                Logger.AppleMusic.debug("""
                    Cookie from document.cookie: \(match ? "✓ MATCH" : "✗ MISMATCH")
                      JS sees \(jsVal.count) chars
                      prefix: \(String(jsVal.prefix(20)))...
                    """)

                // If '+' characters were corrupted to spaces, fix by setting
                // via JavaScript with encodeURIComponent.
                if !match {
                    Logger.AppleMusic.warning(
                        "Token corrupted in cookie storage — applying JS-side fix")
                    let escaped = mediaUserToken
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    _ = try? await webView.callAsyncJavaScript(
                        """
                        document.cookie = 'media-user-token=' + encodeURIComponent('\(escaped)') +
                            '; domain=.apple.com; path=/; secure';
                        """,
                        arguments: [:], in: nil, contentWorld: .page
                    )
                }
            }
        }
    }

    /// Clear the stored token and cookies to sign out.
    public func clearToken() async {
        configuredToken = nil
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        for cookie in cookies where cookie.name == "media-user-token" {
            await cookieStore.deleteCookie(cookie)
        }
        webView.reload()
    }

    // MARK: - Session Lifecycle

    private func startLoading() {
        guard !didStartLoading, let url = URL(string: "https://music.apple.com") else {
            return
        }
        didStartLoading = true
        webView.load(URLRequest(url: url))
    }

    /// Returns after the page has finished loading AND MusicKit is ready.
    private func waitForPageLoad() async {
        // Wait for WKWebView to finish loading the page.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pageLoadContinuation = cont
        }

        // The page DOM is ready, but MusicKit's script may still be loading.
        // Poll a few times for `MusicKit.getInstance().isAuthorized`.
        for _ in 0..<8 {
            if await isAuthorized() {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
    }

    /// Whether the web player reports a completed Apple Music sign-in (i.e. the
    /// injected `media-user-token` cookie was recognised).
    public func isAuthorized() async -> Bool {
        guard configuredToken != nil else { return false }
        let probe = """
        try {
            const music = MusicKit.getInstance();
            return !!(music && music.isAuthorized && music.musicUserToken);
        } catch (error) {
            return false;
        }
        """
        let result = try? await webView.callAsyncJavaScript(
            probe, arguments: [:], in: nil, contentWorld: .page)
        return (result as? Bool) ?? false
    }

    // MARK: - amp-api

    /// Call an amp-api path through the web player's `MusicKit` instance and
    /// return the raw response body as JSON `Data`.
    ///
    /// - Parameter path: an amp-api path, e.g. `/v1/catalog/cn/songs/535824738`.
    public func musicAPI(_ path: String) async throws -> Data {
        let functionBody = """
        const music = MusicKit.getInstance();
        if (!music || !music.api || typeof music.api.music !== 'function') {
            return JSON.stringify({ ok: false, error: 'MusicKit not ready' });
        }
        try {
            const response = await music.api.music(path);
            return JSON.stringify({ ok: true, body: JSON.stringify(response) });
        } catch (error) {
            return JSON.stringify({
                ok: false,
                error: String((error && error.message) ? error.message : error),
            });
        }
        """

        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                functionBody, arguments: ["path": path], in: nil, contentWorld: .page)
        } catch {
            throw AppleMusicError.api(error.localizedDescription)
        }

        guard let jsonString = rawResult as? String,
              let envelopeData = jsonString.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        else {
            throw AppleMusicError.unexpectedResponse
        }

        if envelope["ok"] as? Bool == true {
            guard let bodyString = envelope["body"] as? String,
                  let bodyData = bodyString.data(using: .utf8)
            else {
                throw AppleMusicError.unexpectedResponse
            }

            // `music.api.music(path)` may return either the raw API payload or a
            // Fetch-like response object { url, status, text: "<api_response_json>" }.
            if let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) {
                if let bodyDict = bodyJson as? [String: Any],
                   let textString = bodyDict["text"] as? String,
                   let textData = textString.data(using: .utf8) {
                    return textData
                }
            }
            return bodyData
        }

        let message = envelope["error"] as? String ?? "unknown error"
        if message == "MusicKit not ready" {
            throw AppleMusicError.musicKitUnavailable
        }
        throw AppleMusicError.api(message)
    }
}

// MARK: - WKNavigationDelegate

@available(macOS 12.0, *)
extension AppleMusicWebSession: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoadContinuation?.resume()
        pageLoadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoadContinuation?.resume()
        pageLoadContinuation = nil
    }
}

// MARK: - Logger

extension Logger {
    static let AppleMusic = Logger(
        subsystem: "LyricsKit.AppleMusic", category: "WebSession")
}
