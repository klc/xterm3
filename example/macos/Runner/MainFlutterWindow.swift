import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // Open large enough for `lib/benchmark.dart` to reach a full-screen-sized
    // grid. The benchmark sizes the terminal by resizing a SizedBox, and a
    // SizedBox bigger than the window is silently clipped, so the window is
    // the ceiling on the grid a run can measure - the nib's frame capped it at
    // about 100x37. This has to happen after `super.awakeFromNib()`, which is
    // where the saved frame is restored; setting it before is overwritten.
    self.setFrameAutosaveName("")
    self.isRestorable = false
    var benchFrame = self.frame
    benchFrame.size = NSSize(width: 1440, height: 920)
    if let screen = self.screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      benchFrame.size.width = min(benchFrame.size.width, visible.size.width)
      benchFrame.size.height = min(benchFrame.size.height, visible.size.height)
      benchFrame.origin = NSPoint(
        x: visible.origin.x + (visible.size.width - benchFrame.size.width) / 2,
        y: visible.origin.y + (visible.size.height - benchFrame.size.height) / 2)
    }
    self.setFrame(benchFrame, display: true)
    NSLog("[xterm2-bench] window frame set to %@", NSStringFromRect(self.frame))
  }
}
