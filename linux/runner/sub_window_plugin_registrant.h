#ifndef RUNNER_SUB_WINDOW_PLUGIN_REGISTRANT_H_
#define RUNNER_SUB_WINDOW_PLUGIN_REGISTRANT_H_

#include <flutter_linux/flutter_linux.h>

// Registers project plugins on secondary `desktop_multi_window` engines.
// See `windows/runner/sub_window_plugin_registrant.h` for rationale.
void register_sub_window_plugins(FlPluginRegistry* registry);

#endif  // RUNNER_SUB_WINDOW_PLUGIN_REGISTRANT_H_
