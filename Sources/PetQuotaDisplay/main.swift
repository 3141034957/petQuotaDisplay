import AppKit

let application = NSApplication.shared
let delegate = AppDelegate(followCodex: CommandLine.arguments.contains("--follow-codex"))
application.delegate = delegate
application.run()
