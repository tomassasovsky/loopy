#ifndef RUNNER_SUB_WINDOW_PLUGIN_REGISTRANT_H_
#define RUNNER_SUB_WINDOW_PLUGIN_REGISTRANT_H_

#include <flutter/plugin_registry.h>

// Registers project plugins on secondary `desktop_multi_window` engines.
//
// Do not call [RegisterPlugins] here: sub-windows already register
// `desktop_multi_window` internally, and re-registering it creates a temporary
// inter-window channel whose destructor clears the handler (blank waveform).
//
// When adding a plugin to the project, mirror any sub-window needs from
// `windows/flutter/generated_plugin_registrant.cc` below.
void RegisterSubWindowPlugins(flutter::PluginRegistry* registry);

#endif  // RUNNER_SUB_WINDOW_PLUGIN_REGISTRANT_H_
