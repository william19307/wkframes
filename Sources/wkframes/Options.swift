import AppKit

/// What the command line asked for.
struct Options {
    var url: URL
    var scenario: String
    var out: URL
    var width: CGFloat = 1280
    var height: CGFloat = 800
    var dark = false
    var windowBackground: NSColor?
    var transparentTitlebar = false
    var transparentWebView = false
    var injects: [String] = []
    var timeout: Double = 120
    var fps: Int = 120
    var captureScale: CGFloat = 1
    var interactive = false

    static let usage = """
    wkframes – record what a WKWebView really shows, frame by frame, while a script drives the page.

    usage: wkframes <url> <scenario.js> [options]

      <url>                      http(s):// or file:// page to open
      <scenario.js>              the body of an async function with `probe` in scope (see README)

    the window, as your app makes it:
      --size WxH                 web view size in points (default 1280x800)
      --dark                     dark appearance (NSAppearance .darkAqua)
      --window-bg <css colour>   the window's background colour, e.g. "#111114" or "rgb(17, 17, 20)"
      --transparent-titlebar     full-size content view under a transparent title bar
      --transparent-webview      drawsBackground = false: where the page paints nothing, the window shows through
      --inject <file.js>         a user script at document start, before the page's own (repeatable):
                                 stand-ins for native bridges, a signed-in state, feature flags

    the run:
      --out <dir>                where pictures and result.json go (default ./wkframes-out)
      --fps <n>                  most frames per second to record (default 120; only changed frames arrive)
      --capture-scale <s>        scale of recorded pictures, 0.25–1 (default 1 = the screen's pixels)
      --timeout <seconds>        give up after this long (default 120)
      --interactive              let the mouse reach the window (by default clicks pass through it)

    Exit status: 0 when every probe.check passed, 1 when one failed or the run broke, 2 for a usage error.
    Needs macOS 14+ and Screen Recording permission for the app that runs it (System Settings › Privacy & Security).
    """

    static func parse(_ argv: [String]) -> Options {
        func fail(_ why: String) -> Never {
            FileHandle.standardError.write("wkframes: \(why)\n\n\(usage)\n".data(using: .utf8)!)
            exit(2)
        }
        var positional: [String] = []
        var flags: [String: [String]] = [:]
        var bools: Set<String> = []
        let valued: Set<String> = ["--size", "--window-bg", "--inject", "--out", "--fps", "--capture-scale", "--timeout"]
        let switches: Set<String> = ["--dark", "--transparent-titlebar", "--transparent-webview", "--interactive"]
        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a == "-h" || a == "--help" { print(usage); exit(0) }
            if valued.contains(a) {
                guard i + 1 < argv.count else { fail("\(a) needs a value") }
                flags[a, default: []].append(argv[i + 1])
                i += 2
                continue
            }
            if switches.contains(a) { bools.insert(a); i += 1; continue }
            if a.hasPrefix("--") { fail("unknown option \(a)") }
            positional.append(a)
            i += 1
        }
        guard positional.count == 2 else { fail("give a url and a scenario file") }
        let raw = positional[0]
        let url: URL
        if raw.contains("://") {
            guard let u = URL(string: raw) else { fail("not a url: \(raw)") }
            url = u
        } else {
            url = URL(fileURLWithPath: raw) // a local page by its path
        }
        guard let scenario = try? String(contentsOfFile: positional[1], encoding: .utf8) else { fail("can't read \(positional[1])") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var o = Options(url: url, scenario: scenario, out: cwd.appendingPathComponent("wkframes-out"))
        if let out = flags["--out"]?.last { o.out = URL(fileURLWithPath: out, relativeTo: cwd).standardizedFileURL }
        if let s = flags["--size"]?.last {
            let wh = s.lowercased().split(separator: "x").compactMap { Double($0) }
            guard wh.count == 2, wh[0] >= 200, wh[1] >= 200 else { fail("--size wants WxH, e.g. 1440x900") }
            o.width = wh[0]; o.height = wh[1]
        }
        if let c = flags["--window-bg"]?.last {
            guard let color = cssColor(c) else { fail("--window-bg: can't read \(c)") }
            o.windowBackground = color
        }
        for f in flags["--inject"] ?? [] {
            guard let js = try? String(contentsOfFile: f, encoding: .utf8) else { fail("can't read \(f)") }
            o.injects.append(js)
        }
        if let v = flags["--fps"]?.last { guard let n = Int(v), n > 0 else { fail("--fps wants a number") }; o.fps = n }
        if let v = flags["--capture-scale"]?.last {
            guard let s = Double(v), s >= 0.25, s <= 1 else { fail("--capture-scale wants 0.25–1") }
            o.captureScale = s
        }
        if let v = flags["--timeout"]?.last { guard let t = Double(v), t > 0 else { fail("--timeout wants seconds") }; o.timeout = t }
        o.dark = bools.contains("--dark")
        o.transparentTitlebar = bools.contains("--transparent-titlebar")
        o.transparentWebView = bools.contains("--transparent-webview")
        o.interactive = bools.contains("--interactive")
        return o
    }
}

/// "#rgb", "#rrggbb", "rgb(r, g, b)" or "rgba(r, g, b, a)" – opaque only.
func cssColor(_ s: String) -> NSColor? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("#") {
        var hex = String(t.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    let nums = t.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap { Double($0) }
    guard t.hasPrefix("rgb"), nums.count >= 3 else { return nil }
    return NSColor(srgbRed: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: 1)
}
