import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    SnapshotTool.run(outDir: args[i + 1])
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
