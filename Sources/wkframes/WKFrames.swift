import AppKit

@main
enum WKFrames {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let options = Options.parse(CommandLine.arguments)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon, never takes the focus from what you are doing
        let runner = Runner(options)
        app.delegate = runner
        app.run()
    }
}
