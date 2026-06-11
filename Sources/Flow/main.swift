import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
app.run()
