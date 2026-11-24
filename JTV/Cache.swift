import Foundation
import SwiftUI
import UIKit
import WebKit
import CryptoKit

// MARK: - Networking

enum Net {
    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024)
        config.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: config)
    }()

    static func makeRequest(url: URL, headers: [String: String] = [:], referer: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Cloudflare's JS challenge ("Just a moment…") is served with a
    /// 403/503 (rarely a 200 interstitial). Ordinary Cloudflare pages
    /// also carry challenge-platform scripts, so the body marker alone
    /// is not enough — status or the interstitial title must agree.
    static func isCloudflareChallenge(_ text: String, status: Int) -> Bool {
        let t = text.lowercased()
        if t.contains("<title>just a moment") { return true }
        if status == 403 || status == 503 {
            return t.contains("just a moment")
                || t.contains("challenge-platform")
                || t.contains("challenges.cloudflare.com")
        }
        return false
    }

    /// Marker check for rendered DOM coming back from the WebView
    /// fetcher (no HTTP status available there).
    static func isChallengeHTML(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("<title>just a moment") || t.contains("challenges.cloudflare.com")
    }

    static func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        // Up to 3 attempts with a short backoff: the VPN tunnel path can
        // drop or garble a first response (-1011), a retry usually lands.
        // v1.22: a hard 4xx (except 429) is NOT retried — the old
        // policy burned ~61 s on failures that could never succeed —
        // and the per-attempt timeout drops to 12 s.
        var lastError: Error = URLError(.unknown)
        var triedWebView = false
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.timeoutInterval = 12
                let (data, response) = try await session.data(for: req)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if isCloudflareChallenge(text, status: status) {
                    // Only a real browser passes this wall. Retrying
                    // URLSession just burns time (the user watched a
                    // 4-minute spinner on SayHentai) — go straight to
                    // the WebView fetcher, once.
                    if !triedWebView {
                        triedWebView = true
                        if let html = await WebFetcher.fetchHTML(url: url),
                           !html.isEmpty, !isChallengeHTML(html) {
                            // v1.22.12: the WebView pass harvests
                            // any clearance cookie into the shared
                            // jar (WebFetcher.harvestCookies), so ONE
                            // plain retry now has a real chance of
                            // returning the RAW body — prefer it when
                            // it does. The WebView body is a DOM
                            // serialization (& → &amp; in attribute
                            // values), which has broken downstream
                            // parsers that match on raw markup
                            // (nhplayer's core-script URL — the
                            // hentaihub device fallback). The
                            // WebView body remains the fallback.
                            if let raw = await cfPlainRetry(url: url, headers: headers) {
                                DiagLog.log("net", "cf-detour host=\(url.host ?? "?") result=raw-retry")
                                return raw
                            }
                            DiagLog.log("net", "cf-detour host=\(url.host ?? "?") result=webview")
                            return html
                        }
                    }
                    throw URLError(.badServerResponse)
                }
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                // v1.22.13: nhplayer's /player.php answers a plain
                // URLSession fetch with a variant page whose PoW
                // payload never materialises — the real page only
                // exists once its own JS has run in a browser (the
                // 1.22.12 device log showed raw bodies, no
                // cf-detour, and extraction STILL failing). Force
                // this URL through the browser lane even
                // without a Cloudflare classification. NOTE the
                // preference order here is the OPPOSITE of the CF
                // branch above: the gating on this host is keyed
                // to the client, not to cookies — the phone's
                // WebView on the same IP receives the genuine
                // page while its URLSession fetches receive the
                // variant, so a cookie-warmed plain retry would
                // just fetch the variant again (and the variant
                // passes every cfPlainRetry gate). The WebView
                // body is the only body guaranteed to be what a
                // real browser on this device received, and the
                // hentaihub plugin (v1.0.2) was built and proven
                // to extract from its DOM-serialized form. The
                // raw retry survives only as the fallback for a
                // failed WebView pass.
                // Unlike the CF branch, a failed WebView pass here
                // falls back to the ORIGINAL body: that body is
                // what every build up to 1.22.12 returned for this
                // page, so the forced detour can only improve on
                // today's behaviour, never error where today
                // succeeds. The shared triedWebView gate keeps it
                // to one detour per fetchText call across both
                // triggers.
                // v1.22.14: the 1.22.13 device log proved the
                // player step extracts fine from the lane body —
                // the chain then died at the NEXT hop, the core
                // script /player-core-v2.php, which rides this
                // same plain fetcher and is gated the same way
                // (per-resource, client-keyed). The detour now
                // covers both gated resources (see the predicate
                // below). The forced-mode log lines also gain
                // byte counts — returned body vs the original
                // plain body — so a future log can tell a
                // genuine body from a variant shell or an empty
                // one by size alone (host + numbers only, per
                // the DiagLog redaction rules).
                if isNhplayerGatedResource(url), !triedWebView {
                    triedWebView = true
                    if let html = await WebFetcher.fetchHTML(url: url),
                       !html.isEmpty, !isChallengeHTML(html) {
                        DiagLog.log("net", "cf-detour host=\(url.host ?? "?") result=webview bytes=\(html.utf8.count) plain=\(text.utf8.count)")
                        return html
                    }
                    if let raw = await cfPlainRetry(url: url, headers: headers) {
                        DiagLog.log("net", "cf-detour host=\(url.host ?? "?") result=raw-retry bytes=\(raw.utf8.count) plain=\(text.utf8.count)")
                        return raw
                    }
                    DiagLog.log("net", "cf-detour host=\(url.host ?? "?") result=origin bytes=\(text.utf8.count) plain=\(text.utf8.count)")
                    return text
                }
                return text
            } catch {
                // L-16 (1.3.6): the tvOS 1.3.1 per-attempt
                // transport record (L-T17/FL-385), ported —
                // without it the error was reduced to
                // lastError and thrown with no trace, so a
                // refused hop was undiagnosable from the
                // device log (the 123av silent death).
                DiagLog.log("net", "fetchText failed host=\(url.host ?? "?") attempt=\(attempt) status=\(attemptStatus) err=\((error as NSError).domain)#\((error as NSError).code)")
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    /// The ONE plain retry fetchText is allowed after a WebView
    /// Cloudflare pass (v1.22.12): same request shape as a normal
    /// attempt, no retries of its own, and it never throws — any
    /// failure (transport, non-2xx, or a body that is still a
    /// challenge) returns nil and the caller keeps the WebView
    /// body. Cancellation is not propagated from here on purpose:
    /// the WebView detour it follows is not cancellation-aware
    /// either (fetchHTML completes regardless), so the detour's
    /// semantics stay uniform.
    private static func cfPlainRetry(url: URL, headers: [String: String]) async -> String? {
        var req = makeRequest(url: url, headers: headers)
        req.timeoutInterval = 12
        guard let (data, response) = try? await session.data(for: req) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200...299).contains(status) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard !isCloudflareChallenge(text, status: status), !isChallengeHTML(text) else { return nil }
        return text
    }

    /// The forced-detour targets (v1.22.13, extended
    /// v1.22.14): nhplayer's gated resources — the player page
    /// (/player.php) and its PoW core script
    /// (/player-core-v2.php), the two hops of the hentaihub
    /// chain this host serves as client-keyed variants to a
    /// plain fetcher. The host must be the bare domain or a
    /// subdomain of it, and the path exactly one of the two
    /// (URL.path never carries the query, so ?vid=… / ?t=…&_=…
    /// do not disturb the match).
    private static func isNhplayerGatedResource(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard host == "nhplayer.com" || host.hasSuffix(".nhplayer.com") else { return false }
        return url.path == "/player.php" || url.path == "/player-core-v2.php"
    }

    /// POST variant for plugin hop configs that carry a postBody
    /// (e.g. vlxx's /ajax.php player call). Same retry policy.
    static func fetchTextPOST(_ urlString: String, body: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.httpMethod = "POST"
                req.timeoutInterval = 12
                if req.value(forHTTPHeaderField: "Content-Type") == nil {
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
                req.httpBody = body.data(using: .utf8)
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            } catch {
                // L-16 (1.3.6): same per-attempt transport
                // record as fetchText (see above).
                DiagLog.log("net", "fetchTextPOST failed host=\(url.host ?? "?") attempt=\(attempt) status=\(attemptStatus) err=\((error as NSError).domain)#\((error as NSError).code)")
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    static func fetchData(_ urlString: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        // v1.22: same retry policy as fetchText (was: zero retries).
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do {
                return try await session.data(for: makeRequest(url: url, headers: headers)).0
            } catch {
                // L-16 (1.3.6): same per-attempt transport
                // record as fetchText (see above).
                DiagLog.log("net", "fetchData failed host=\(url.host ?? "?") attempt=\(attempt) err=\((error as NSError).domain)#\((error as NSError).code)")
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }
}

// MARK: - WebView fetcher (Cloudflare-challenge fallback)

/// Some sources (SayHentai) sit behind Cloudflare's JavaScript
/// challenge: plain URLSession requests receive a "Just a moment…"
/// page or stall, while a real WebKit view passes the check. This
/// fetcher loads the page in an off-screen WKWebView, lets the
/// challenge solve itself, returns the rendered HTML, and copies the
/// clearance cookies into the shared cookie jar so Net.session can
/// fetch follow-up pages and chapter images directly (the clearance
/// is bound to this device's IP + user agent, both unchanged).
@MainActor
final class WebFetcher: NSObject, WKNavigationDelegate {
    static let shared = WebFetcher()

    /// One browser lane. v1.22: TWO lanes — Cloudflare-walled
    /// fetches (sayhentai list/detail/chapter) used to queue
    /// behind each other through a single webview, so a chapter
    /// open behind a list fetch could wait 10–40 s. Both lanes
    /// share the default website data store, so one lane's
    /// clearance serves the other (and Net.session, via the
    /// harvested cookies).
    private final class Lane {
        var webView: WKWebView?
        var continuation: CheckedContinuation<String?, Never>?
        var dataContinuation: CheckedContinuation<Data?, Never>?
        /// How many extract loops are currently polling for the
        /// lane's in-flight bytes load. One navigation can fire
        /// several didFinish callbacks (challenge → redirect →
        /// real document), each spawning a loop; only the LAST
        /// loop out may deliver a nil verdict, so a slow loop
        /// can't kill a load another loop is about to satisfy.
        var extractorsRunning = 0
        /// Monotonic tag of the lane's current bytes load. Loops
        /// and timeouts act only for the generation that spawned
        /// them, so a loop that outlives a timed-out load cannot
        /// deliver a verdict into the NEXT load on the same lane.
        var dataGeneration = 0
        var extractorsGeneration = 0
        var timeoutTask: Task<Void, Never>?
        var busy = false
    }

    private var lanes: [Lane] = [Lane(), Lane()]

    static func fetchHTML(url: URL) async -> String? {
        await shared.fetch(url: url)
    }

    /// One clearance task per HOST per session: a rail of twenty
    /// covers behind the same wall shares a single WebView round,
    /// and concurrent callers await the same task rather than
    /// stampeding the lanes.
    private var clearanceTasks: [String: Task<String?, Never>] = [:]

    /// Clears a host's Cloudflare wall once per session by loading
    /// its root in a WebView lane (which also harvests the
    /// clearance cookies into the shared jar).
    static func ensureClearance(for url: URL) async {
        await shared.ensureClearance(url: url)
    }

    private func ensureClearance(url: URL) async {
        guard let host = url.host, !host.isEmpty else { return }
        if let existing = clearanceTasks[host] {
            _ = await existing.value
            return
        }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        components.path = "/"
        guard let root = components.url else { return }
        let task = Task { @MainActor in await self.fetch(url: root) }
        clearanceTasks[host] = task
        _ = await task.value
    }

    /// Last-resort image bytes: loads the image URL in a WebView
    /// lane (passing any challenge on the way) and reads the image
    /// back out of the rendered document. The caller's headers
    /// (e.g. a Referer a CDN demands) ride along on the load.
    static func fetchImageData(url: URL, headers: [String: String] = [:]) async -> Data? {
        await shared.fetchBytes(url: url, headers: headers)
    }

    private func fetchBytes(url: URL, headers: [String: String]) async -> Data? {
        // v1.22.15 (B-5): lane-wait duration — logged only when
        // the grant needed at least one 200 ms poll wait; a
        // first-try grant logs nothing. No lane behaviour change.
        let enteredAt = Date()
        var waited = false
        while true {
            if let lane = lanes.first(where: { !$0.busy }) {
                lane.busy = true
                if waited {
                    DiagLog.log("lane", "kind=bytes waited_ms=\(Int(Date().timeIntervalSince(enteredAt) * 1000))")
                }
                let data = await loadBytes(url: url, lane: lane, headers: headers)
                lane.busy = false
                return data
            }
            // L-17 (1.3.6): a waiter used to poll forever —
            // uncancellable, no deadline — so a flooded lane
            // starved image loads for an entire session (the
            // 785 s grant in the 2026-11-22 log). A waiter
            // now gives up at ~20 s or on cancellation; the
            // caller lands on the same placeholder it reaches
            // today, minutes sooner.
            if Task.isCancelled { return nil }
            if Date().timeIntervalSince(enteredAt) >= 20 {
                // 1.22.19 (L-17 amendment): a dropped waiter
                // used to leave no trace — the expiry is now
                // on the record with the wait it paid.
                DiagLog.log("lane", "kind=bytes outcome=waiter-expired waited_ms=\(Int(Date().timeIntervalSince(enteredAt) * 1000))")
                return nil
            }
            waited = true
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func loadBytes(url: URL, lane: Lane, headers: [String: String]) async -> Data? {
        let wv = ensureWebView(lane: lane)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            lane.dataGeneration += 1
            let generation = lane.dataGeneration
            lane.dataContinuation = cont
            lane.timeoutTask = Task { @MainActor in
                // L-17 (1.3.6): 40 s → 15 s for BYTES loads
                // — the extractor's nil path resolves in
                // ~9.3 s when a navigation completes, so an
                // image navigation unfinished at 15 s is
                // dead and only holds its lane hostage. The
                // HTML load below keeps 40 s (challenge
                // solving legitimately takes longer).
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self.finishData(lane: lane, nil, generation: generation)
            }
            wv.stopLoading()
            wv.load(Net.makeRequest(url: url, headers: headers))
        }
    }

    private func finishData(lane: Lane, _ data: Data?, generation: Int? = nil) {
        if let generation, generation != lane.dataGeneration { return }
        lane.timeoutTask?.cancel()
        lane.timeoutTask = nil
        lane.dataContinuation?.resume(returning: data)
        lane.dataContinuation = nil
    }

    /// Entry point for a bytes load's didFinish. Several extract
    /// loops may poll for the same load (one per didFinish the
    /// navigation produces); bytes from ANY loop win, and a nil
    /// verdict is delivered only by the last loop out — the load's
    /// own timeout remains the final backstop.
    private func extractImageBytes(lane: Lane, webView: WKWebView, generation: Int) async {
        if lane.extractorsGeneration != generation {
            lane.extractorsGeneration = generation
            lane.extractorsRunning = 0
        }
        lane.extractorsRunning += 1
        let data = await pollForImageBytes(lane: lane, webView: webView, generation: generation)
        guard lane.extractorsGeneration == generation else { return }
        lane.extractorsRunning -= 1
        if let data {
            await self.harvestCookies(from: webView)
            self.finishData(lane: lane, data, generation: generation)
        } else if lane.extractorsRunning == 0 {
            await self.harvestCookies(from: webView)
            self.finishData(lane: lane, nil, generation: generation)
        }
    }

    /// Polls the lane's document until it holds a loaded image
    /// (a challenge page has none), then draws it to a canvas and
    /// returns the PNG bytes. Same-origin image documents are not
    /// canvas-tainted, so the pixels are readable.
    private func pollForImageBytes(lane: Lane, webView: WKWebView, generation: Int) async -> Data? {
        let script = """
        (() => {
          const img = document.images && document.images[0];
          if (!img || !img.complete || img.naturalWidth === 0 || img.naturalHeight === 0) return '';
          if (img.naturalHeight > 6000) return '';
          const c = document.createElement('canvas');
          c.width = img.naturalWidth; c.height = img.naturalHeight;
          c.getContext('2d').drawImage(img, 0, 0);
          return c.toDataURL('image/png');
        })()
        """
        for attempt in 0..<8 {
            try? await Task.sleep(nanoseconds: attempt == 0 ? 900_000_000 : 1_200_000_000)
            if lane.dataContinuation == nil || lane.dataGeneration != generation { return nil }
            let raw = try? await webView.evaluateJavaScript(script)
            guard let dataURL = raw as? String, dataURL.hasPrefix("data:"),
                  let comma = dataURL.firstIndex(of: ",") else { continue }
            let b64 = String(dataURL[dataURL.index(after: comma)...])
            if let data = Data(base64Encoded: b64), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private func fetch(url: URL) async -> String? {
        // v1.22.15 (B-5): lane-wait duration — logged only when
        // the grant needed at least one 200 ms poll wait; a
        // first-try grant logs nothing. No lane behaviour change.
        let enteredAt = Date()
        var waited = false
        while true {
            if let lane = lanes.first(where: { !$0.busy }) {
                lane.busy = true
                if waited {
                    DiagLog.log("lane", "kind=html waited_ms=\(Int(Date().timeIntervalSince(enteredAt) * 1000))")
                }
                let html = await load(url: url, lane: lane)
                lane.busy = false
                return html
            }
            // L-17 (1.3.6): same waiter deadline +
            // cancellation check as the bytes loop above —
            // the two loops share the lane pool, so an
            // unbounded waiter here starves it identically.
            if Task.isCancelled { return nil }
            if Date().timeIntervalSince(enteredAt) >= 20 {
                // 1.22.19 (L-17 amendment): same expiry
                // record as the bytes loop above.
                DiagLog.log("lane", "kind=html outcome=waiter-expired waited_ms=\(Int(Date().timeIntervalSince(enteredAt) * 1000))")
                return nil
            }
            waited = true
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func ensureWebView(lane: Lane) -> WKWebView {
        if let webView = lane.webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = Net.defaultUA
        wv.navigationDelegate = self
        lane.webView = wv
        // Attach invisibly to the key window: WebKit can throttle JS
        // timers in fully detached views, and the challenge is JS.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            wv.isHidden = true
            window.addSubview(wv)
        }
        return wv
    }

    private func lane(for webView: WKWebView) -> Lane? {
        lanes.first(where: { $0.webView === webView })
    }

    private func load(url: URL, lane: Lane) async -> String? {
        let wv = ensureWebView(lane: lane)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            lane.continuation = cont
            lane.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                self.finish(lane: lane, nil)
            }
            var req = URLRequest(url: url)
            req.setValue(Net.defaultUA, forHTTPHeaderField: "User-Agent")
            wv.stopLoading()
            wv.load(req)
        }
    }

    private func finish(lane: Lane, _ html: String?) {
        lane.timeoutTask?.cancel()
        lane.timeoutTask = nil
        lane.continuation?.resume(returning: html)
        lane.continuation = nil
    }

    private func harvestCookies(from webView: WKWebView) async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let lane = lane(for: webView) else { return }
        Task { @MainActor in
            if lane.dataContinuation != nil {
                await self.extractImageBytes(lane: lane, webView: webView, generation: lane.dataGeneration)
                return
            }
            // The challenge needs a beat to solve and redirect; poll
            // the DOM until it turns into the real page. A
            // cf_clearance cookie means the wall is already passed
            // even if this frame still shows the challenge shell —
            // one short extra beat, then take the DOM as-is.
            for attempt in 0..<6 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 800_000_000 : 1_200_000_000)
                let raw = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
                guard let html = raw as? String else { continue }
                if Net.isChallengeHTML(html) {
                    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    if cookies.contains(where: { $0.name == "cf_clearance" }) {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        let settled = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
                        if let settledHTML = settled as? String, !Net.isChallengeHTML(settledHTML) {
                            await self.harvestCookies(from: webView)
                            self.finish(lane: lane, settledHTML)
                            return
                        }
                    }
                    continue
                }
                await self.harvestCookies(from: webView)
                self.finish(lane: lane, html)
                return
            }
            let raw = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
            self.finish(lane: lane, raw as? String)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let lane = lane(for: webView) { finish(lane: lane, nil); finishData(lane: lane, nil) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let lane = lane(for: webView) { finish(lane: lane, nil); finishData(lane: lane, nil) }
    }
}

// MARK: - Image cache

final class ImageCacheManager: @unchecked Sendable {
    static let shared = ImageCacheManager()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Cache keys whose full WebView fallback ladder already
    /// failed this session (see fetchBytesWithFallback).
    private var fallbackFailed: Set<String> = []
    /// L-17 (1.3.6): per-HOST ladder count this session —
    /// the circuit breaker in fetchBytesWithFallback.
    /// Reset by clear(), together with the per-URL memo
    /// above. 1.22.19 (L-17 amendment): the counter counts
    /// ladder ENTRIES, not completed failures — see the
    /// breaker site in fetchBytesWithFallback.
    private var hostLadderEntries: [String: Int] = [:]
    /// I-5 (AUDIT-IOS): prefetch pending queue + active count,
    /// guarded by `lock` like inFlight. At most
    /// `prefetchWorkers` prefetch loads run at once (the tvOS
    /// bound); visible-card loads via loadImage are not counted.
    private var prefetchQueue: [(urlString: String, headers: [String: String], key: String)] = []
    private var prefetchActive = 0
    private static let prefetchWorkers = 3
    private let lock = NSLock()
    /// v1.22 disk tier (~300 MB, LRU by modification date): every
    /// cold launch used to re-download every poster — the memory
    /// cache alone could not survive a relaunch.
    private let diskDir: URL
    private let diskCap = 300 * 1024 * 1024

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 256 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("jtv-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        let dir = diskDir, cap = diskCap
        Task.detached { Self.pruneDisk(dir: dir, cap: cap) }
    }

    private func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(digest)
    }

    private static func pruneDisk(dir: URL, cap: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var total = 0
        var sized: [(url: URL, size: Int, date: Date)] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            sized.append((entry, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > cap else { return }
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            if total <= cap { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Real memory cost of a decoded bitmap. The old accounting
    /// used the COMPRESSED byte count, so the 256 MB cap was
    /// fictitious — decoded posters run 5–15× their file size.
    private func decodedCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    /// Caps pathological decodes (4K backdrops) at a 2048 px long
    /// edge; normal posters and manga pages pass through untouched.
    /// A reading page or strip is NEVER capped: its short edge is
    /// the reading width (a SayHentai strip runs ~720 x 10000), and
    /// capping the long edge crushed one to ~147 px wide — the
    /// owner-reported "very blurry" pages of 2026-11-18, which the
    /// plugin's HD files never caused. Only an image large in BOTH
    /// dimensions (a backdrop, a photo) is capped. The disk tier
    /// stores the original bytes, so this fix also heals chapters
    /// already cached on the device.
    private func capped(_ image: UIImage) -> UIImage {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longest = max(pixelW, pixelH)
        guard longest > 2048 else { return image }
        guard min(pixelW, pixelH) > 1080 else { return image }
        let ratio = 2048 / longest
        let target = CGSize(width: pixelW * ratio, height: pixelH * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func key(for url: String, headers: [String: String]) -> String {
        if headers.isEmpty { return url }
        let suffix = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return url + "|" + suffix
    }

    func cachedImage(for urlString: String, headers: [String: String] = [:]) -> UIImage? {
        cache.object(forKey: key(for: urlString, headers: headers) as NSString)
    }

    func loadImage(urlString: String, headers: [String: String] = [:]) async -> UIImage? {
        let k = key(for: urlString, headers: headers)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        guard let url = URL(string: urlString) else { return nil }

        // Swift 6: NSLock.lock()/unlock() are unavailable in
        // async contexts; scoped withLock is the sanctioned
        // form. The check-and-set MUST stay inside ONE critical
        // section — the pre-migration code held the lock across
        // the check, the Task creation and the registration,
        // and splitting that into two sections (an earlier
        // conversion did) loses the dedupe guarantee: two
        // concurrent calls could both miss the check and both
        // fetch, and a finishing task's cleanup could clear a
        // successor's registration. So the task is created AND
        // registered inside a single withLock section that
        // returns it; the section itself never awaits.
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[k] { return existing }
            let created = Task<UIImage?, Never> {
                defer {
                    self.lock.withLock { self.inFlight[k] = nil }
                }
                // Disk tier first: decode + promote to memory.
                let disk = self.diskURL(for: k)
                if let data = try? Data(contentsOf: disk), let image = UIImage(data: data) {
                    let cappedImage = self.capped(image)
                    self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                    return cappedImage
                }
                guard let data = await self.fetchBytesWithFallback(url: url, headers: headers, cacheKey: k),
                      let image = UIImage(data: data) else { return nil }
                try? data.write(to: disk, options: .atomic)
                let cappedImage = self.capped(image)
                self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                return cappedImage
            }
            inFlight[k] = created
            return created
        }
        return await task.value
    }

    /// Direct fetch first — the overwhelming majority of hosts
    /// answer it and nothing changes for them. Hosts behind a
    /// Cloudflare wall refuse the plain request even though the
    /// same app's TEXT fetches get through (they have a WebView
    /// fallback; image loads never did — SayHentai covers sat
    /// behind the wall while its lists loaded fine). Only a
    /// wall-shaped failure (401/403/503 or a challenge body)
    /// escalates: clear the host's wall once via the WebView,
    /// retry direct (clearance cookies are in the shared jar by
    /// then, and the user agent matches the WebView's), and as a
    /// last resort pull the bytes out of the WebView itself.
    /// Ordinary failures (404, dead host, timeout) fail exactly
    /// as before and never touch the WebView lanes; a URL whose
    /// whole ladder failed is remembered for the session so
    /// re-scrolling a dead rail doesn't re-pay it.
    private func fetchBytesWithFallback(url: URL, headers: [String: String], cacheKey: String) async -> Data? {
        // Some hosts (sayhentai.cx's /storage/ covers, measured
        // 2026-11-18) refuse image requests that arrive with no
        // Referer at all — Cloudflare serves its hard block page
        // even to Safari on a direct image navigation, while the
        // same image loads fine inside the site's own pages. A
        // browser loading an image embedded in a page sends that
        // page as the Referer; with no caller-supplied Referer,
        // send the image host's own root — the closest equivalent
        // (the site's pages are the only referrers these images
        // ever legitimately have). Callers that pass an explicit
        // Referer (the manga reader) keep theirs.
        var hdrs = headers
        if !hdrs.keys.contains(where: { $0.lowercased() == "referer" }), let host = url.host, !host.isEmpty {
            hdrs["Referer"] = "\(url.scheme ?? "https")://\(host)/"
        }
        func direct() async -> (data: Data?, wall: Bool) {
            var req = Net.makeRequest(url: url, headers: hdrs)
            req.timeoutInterval = 30
            guard let (data, response) = try? await Net.session.data(for: req) else { return (nil, false) }
            if UIImage(data: data) != nil { return (data, false) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 || status == 503 { return (nil, true) }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return (nil, Net.isCloudflareChallenge(text, status: status))
        }
        let first = await direct()
        if let data = first.data { return data }
        guard first.wall else { return nil }
        if lock.withLock({ fallbackFailed.contains(cacheKey) }) { return nil }
        // L-17 (1.3.6): per-host circuit breaker. The per-URL
        // memo above cannot stop a wall-refusing host with
        // endless unique URLs (fourhoi.com, MissAV's image
        // CDN): every poster paid a clearance + lane burn and
        // the 2 WebView lanes drowned for a whole session
        // (2026-11-22 log — lane waits climbed to 785 s).
        // After 3 this session the host fails right here:
        // the direct attempt above still runs (a recovered
        // host serves again immediately), but no clearance
        // and no lane are spent on it.
        // 1.22.19 (L-17 amendment): the count is taken at
        // ladder ENTRY, not at ladder completion. The
        // 1.22.18 log showed why completion counting fails:
        // prefetch fires up to 60 loads at once, so bursts
        // of ×8/×19 simultaneous fourhoi loads ALL passed
        // this check while the counter still read 0 — the
        // first completed failure only landed ~15-40 s
        // later. Counting the entry (here, before any
        // clearance or lane is spent) trips the breaker
        // after 3 entries even mid-burst. A host whose
        // ladder WORKS is unaffected in practice: once
        // clearance lands, direct attempts succeed and
        // the ladder is never entered again.
        if let host = url.host, !host.isEmpty {
            let entered = lock.withLock { () -> Bool in
                if (hostLadderEntries[host] ?? 0) >= 3 { return false }
                hostLadderEntries[host, default: 0] += 1
                return true
            }
            guard entered else { return nil }
        }
        await WebFetcher.ensureClearance(for: url)
        if let data = (await direct()).data { return data }
        if let data = await WebFetcher.fetchImageData(url: url, headers: hdrs) { return data }
        // The whole ladder failed: log the HOST only (DiagLog
        // law — never the signed/full URL) so a dead image host
        // is diagnosable from the exported log.
        DiagLog.log("image", "fallback ladder failed host=\(url.host ?? "?")")
        // The per-URL memo is the only completion-side
        // record now — the host's breaker count was
        // already taken at ladder entry (1.22.19).
        lock.withLock {
            _ = fallbackFailed.insert(cacheKey)
        }
        return nil
    }

    /// Warms memory/disk for images about to be scrolled into
    /// (rails after a section lands, the manga reader's next
    /// pages). Deduped against the cache and in-flight loads.
    func prefetch(urlStrings: [String], headers: [String: String] = [:]) {
        // I-5 (AUDIT-IOS): the same URLs as before (first 60 of
        // each call, already-cached ones skipped) now go through
        // a pending queue drained by at most `prefetchWorkers`
        // concurrent loads — the BOUND ported from the tvOS
        // ImageCacheManager. Unlike tvOS, a new call does NOT
        // replace the queue: nothing a caller asked for is
        // dropped. The new batch goes to the FRONT (in its own
        // order) so the latest caller — e.g. the manga reader's
        // next pages — is not stuck behind older Home rails.
        lock.withLock {
            var batch: [(urlString: String, headers: [String: String], key: String)] = []
            var batchKeys = Set<String>()
            for urlString in urlStrings.prefix(60) {
                let k = key(for: urlString, headers: headers)
                if cache.object(forKey: k as NSString) != nil { continue }
                if !batchKeys.insert(k).inserted { continue }
                batch.append((urlString, headers, k))
            }
            guard !batch.isEmpty else { return }
            prefetchQueue.removeAll { batchKeys.contains($0.key) }
            prefetchQueue.insert(contentsOf: batch, at: 0)
        }
        pumpPrefetch()
    }

    /// I-5: claims pending items under the lock (never awaiting
    /// while holding it) and starts their loads; each finished
    /// load frees its slot and re-pumps. Entries that became
    /// cached or in flight (e.g. a visible card started them)
    /// since enqueue are dropped without consuming a slot —
    /// loadImage's own in-flight dedupe would have joined them.
    private func pumpPrefetch() {
        while true {
            let item: (urlString: String, headers: [String: String], key: String)? = lock.withLock {
                while prefetchActive < Self.prefetchWorkers, !prefetchQueue.isEmpty {
                    let next = prefetchQueue.removeFirst()
                    if cache.object(forKey: next.key as NSString) != nil { continue }
                    if inFlight[next.key] != nil { continue }
                    prefetchActive += 1
                    return next
                }
                return nil
            }
            guard let item else { return }
            Task {
                _ = await self.loadImage(urlString: item.urlString, headers: item.headers)
                self.lock.withLock { self.prefetchActive -= 1 }
                self.pumpPrefetch()
            }
        }
    }

    func clear() {
        cache.removeAllObjects()
        // v1.22.15 (F-2): the Settings action ("Xoá bộ nhớ đệm
        // ảnh") now tells the truth — it also empties the disk
        // tier and resets the session failure memo, not just
        // the memory tier. Synchronous on purpose: clear() is
        // an explicit user action and the disk directory is
        // empty when it returns.
        if let entries = try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        lock.withLock {
            fallbackFailed.removeAll()
            hostLadderEntries.removeAll()
        }
    }
}

/// Async image view backed by ImageCacheManager (supports custom headers,
/// e.g. the Referer manga CDNs require).
struct CachedAsyncImage: View {
    let urlString: String
    var headers: [String: String] = [:]
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    /// v1.22.15 (F-1): the task identity MUST match
    /// ImageCacheManager.key(for:headers:) — the URL alone
    /// when headers is empty, else the URL + "|" + the
    /// headers sorted by key as "k=v" joined by "&" — so the
    /// view reloads exactly when the manager's cache entry
    /// would differ (a same-URL/different-headers request is
    /// a different image to the manager, and now to the view).
    private var identity: String {
        if headers.isEmpty { return urlString }
        let suffix = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return urlString + "|" + suffix
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.25))
                    }
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay { ProgressView().tint(.white.opacity(0.5)) }
            }
        }
        .task(id: identity) {
            image = nil
            failed = false
            if let cached = ImageCacheManager.shared.cachedImage(for: urlString, headers: headers) {
                image = cached
                return
            }
            let loaded = await ImageCacheManager.shared.loadImage(urlString: urlString, headers: headers)
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
