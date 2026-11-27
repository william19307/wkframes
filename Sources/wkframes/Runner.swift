import AppKit
import ScreenCaptureKit
import WebKit

/// One run: a window made the way the options say, the page in the system WKWebView, the scenario, the result.
final class Runner: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    let o: Options
    var window: NSWindow!
    var web: WKWebView!
    private var started = false
    private var scWindow: SCWindow?

    init(_ o: Options) { self.o = o }

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: o.width, height: o.height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "wkframes"
        if o.transparentTitlebar {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        window.appearance = NSAppearance(named: o.dark ? .darkAqua : .aqua)
        if let bg = o.windowBackground { window.backgroundColor = bg }
        // WebKit slows or stops drawing a window that is covered: this one stays on top while it records, and lets
        // clicks through so a press at the Mac can't change the page under the scenario
        window.level = .floating
        window.ignoresMouseEvents = !o.interactive

        let cfg = WKWebViewConfiguration()
        let uc = cfg.userContentController
        uc.addUserScript(WKUserScript(source: ProbeScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for js in o.injects { uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        uc.add(self, name: "wkframesDone")
        uc.addScriptMessageHandler(self, contentWorld: .page, name: "wkframesShot")
        uc.addScriptMessageHandler(self, contentWorld: .page, name: "wkframesRec")
        cfg.preferences.isElementFullscreenEnabled = true

        web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
        web.isInspectable = true // Safari › Develop can attach while it runs
        web.allowsMagnification = false
        if o.transparentWebView { web.setValue(false, forKey: "drawsBackground") }
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        if o.url.isFileURL {
            web.loadFileURL(o.url, allowingReadAccessTo: o.url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: o.url))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + o.timeout) { [weak self] in
            self?.finish(["error": "timed out after \(Int(self?.o.timeout ?? 0)) s"], status: 1)
        }
    }

    // MARK: the page

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        guard !started else { return }
        started = true
        w.evaluateJavaScript(ProbeScript.run(o.scenario)) { [weak self] _, err in
            if let err { self?.finish(["error": "scenario did not start: \(err.localizedDescription)"], status: 1) }
        }
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        finish(["error": "could not load \(o.url.absoluteString): \(error.localizedDescription)"], status: 1)
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        finish(["error": "the web content process ended"], status: 1)
    }

    // MARK: messages from the scenario

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "wkframesDone", let s = message.body as? String,
              let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return finish(["error": "the scenario's result could not be read"], status: 1)
        }
        let checks = obj["checks"] as? [[String: Any]] ?? []
        for c in checks {
            let ok = c["ok"] as? Bool ?? false
            let detail = (c["detail"] as? String).flatMap { $0.isEmpty ? nil : " – \($0)" } ?? ""
            print("\(ok ? "PASS" : "FAIL") \(c["id"] ?? "") \(c["what"] ?? "")\(detail)")
        }
        let failed = obj["error"] != nil || checks.contains { !($0["ok"] as? Bool ?? false) }
        finish(obj, status: failed ? 1 : 0)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        switch message.name {
        case "wkframesShot":
            let name = safeName(message.body as? String ?? "shot")
            Task { @MainActor in
                do {
                    let img = try await SCScreenshotManager.captureImage(contentFilter: try await filter(), configuration: config())
                    let url = o.out.appendingPathComponent("\(name).png")
                    writePNG(img, to: url)
                    replyHandler(url.path, nil)
                } catch { replyHandler(nil, "shot failed: \(error.localizedDescription) – is Screen Recording allowed?") }
            }
        case "wkframesRec":
            let b = message.body as? [String: Any] ?? [:]
            let name = safeName(b["name"] as? String ?? "rec")
            let ms = (b["ms"] as? NSNumber)?.doubleValue ?? 1000
            let save = b["save"] as? Bool ?? true
            let pts = (b["points"] as? [[NSNumber]] ?? []).compactMap { $0.count == 2 ? pixel(css: CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue)) : nil }
            Task { @MainActor in
                do {
                    let rec = Recorder(points: pts, keepImages: save)
                    let stream = SCStream(filter: try await filter(), configuration: config(), delegate: nil)
                    try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "wkframes.rec"))
                    try await stream.startCapture()
                    // tell the scenario once the first frame is in, so what it does next is on the recording
                    for _ in 0..<50 where rec.snapshot().isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
                    _ = try? await web.evaluateJavaScript("window.probe._started[\(jsString(name))]?.(); 0")
                    try await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
                    try await stream.stopCapture()
                    var list: [[String: Any]] = []
                    for (i, f) in rec.snapshot().enumerated() {
                        var entry: [String: Any] = ["t": (f.t * 10).rounded() / 10]
                        if let img = f.image {
                            let file = String(format: "%@-%03d.png", name, i)
                            writePNG(img, to: o.out.appendingPathComponent(file))
                            entry["file"] = file
                        }
                        if !f.px.isEmpty { entry["px"] = f.px }
                        list.append(entry)
                    }
                    if let json = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
                        try? json.write(to: o.out.appendingPathComponent("\(name).json"))
                    }
                    replyHandler(["dir": o.out.path, "frames": list], nil)
                } catch { replyHandler(nil, "recording failed: \(error.localizedDescription) – is Screen Recording allowed?") }
            }
        default:
            replyHandler(nil, "unknown message")
        }
    }

    // MARK: capture

    private func filter() async throws -> SCContentFilter {
        if scWindow == nil {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scWindow = content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
        }
        guard let w = scWindow else { throw NSError(domain: "wkframes", code: 1, userInfo: [NSLocalizedDescriptionKey: "the window is not shareable"]) }
        return SCContentFilter(desktopIndependentWindow: w)
    }

    private var pixelScale: CGFloat { window.backingScaleFactor * o.captureScale }

    private func config() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(window.frame.width * pixelScale)
        c.height = Int(window.frame.height * pixelScale)
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        c.queueDepth = 8
        return c
    }

    /// a point of the page (CSS pixels from the web view's top left) in the recorded picture's pixels
    private func pixel(css p: CGPoint) -> CGPoint {
        let r = web.convert(web.bounds, to: nil) // window coordinates, origin bottom left
        let top = window.frame.height - r.maxY
        return CGPoint(x: (r.minX + p.x) * pixelScale, y: (top + p.y) * pixelScale)
    }

    private func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    private func safeName(_ s: String) -> String {
        let ok = s.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        return ok.isEmpty ? "shot" : ok
    }

    private func finish(_ result: [String: Any], status: Int32) {
        if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: o.out.appendingPathComponent("result.json"))
            if let err = result["error"] { FileHandle.standardError.write("wkframes: \(err)\n".data(using: .utf8)!) }
        }
        print("result: \(o.out.appendingPathComponent("result.json").path)")
        exit(status)
    }
}
