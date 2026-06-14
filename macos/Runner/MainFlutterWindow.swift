import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register non-multi-window plugins for secondary engines. Sub-windows
    // already register `desktop_multi_window` before this callback.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterSubWindowPlugins(registry: controller)
    }

    super.awakeFromNib()
  }
}
