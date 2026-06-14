import FlutterMacOS
import screen_retriever_macos
import shared_preferences_foundation
import url_launcher_macos
import window_manager

/// Registers project plugins on secondary `desktop_multi_window` engines.
///
/// Do not call [RegisterGeneratedPlugins] here: sub-windows already register
/// `desktop_multi_window` internally, and re-registering it re-attaches the
/// main window and can break inter-window messaging (blank waveform).
///
/// When adding a plugin, mirror any sub-window needs from
/// `macos/Flutter/GeneratedPluginRegistrant.swift` below.
func RegisterSubWindowPlugins(registry: FlutterPluginRegistry) {
  ScreenRetrieverMacosPlugin.register(with: registry.registrar(forPlugin: "ScreenRetrieverMacosPlugin"))
  SharedPreferencesPlugin.register(with: registry.registrar(forPlugin: "SharedPreferencesPlugin"))
  UrlLauncherPlugin.register(with: registry.registrar(forPlugin: "UrlLauncherPlugin"))
  WindowManagerPlugin.register(with: registry.registrar(forPlugin: "WindowManagerPlugin"))
}
