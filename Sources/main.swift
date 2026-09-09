import AppKit
import Darwin
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate(root: Runtime.dataRoot)
application.delegate = delegate
application.run()
