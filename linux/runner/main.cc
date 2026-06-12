#include <glib.h>
#include <stdlib.h>

#include "my_application.h"

// Impeller is the default renderer on Linux/GTK as of Flutter 3.44, but it
// mis-rasterizes the bundled Material icon font there — icons render as empty
// "tofu" boxes. Until Linux Impeller matures, force the Skia backend.
//
// The GTK embedder reads engine switches from the FLUTTER_ENGINE_SWITCHES /
// FLUTTER_ENGINE_SWITCH_<N> environment variables, which is also how the
// `flutter` tool passes its own switches for `flutter run`. We therefore
// *append* our switch to whatever is already set rather than overwrite it, so
// debug-run switches keep working.
static void force_skia_renderer() {
  const gchar* count_str = g_getenv("FLUTTER_ENGINE_SWITCHES");
  int count = count_str != nullptr ? atoi(count_str) : 0;
  count += 1;

  g_autofree gchar* switch_key = g_strdup_printf("FLUTTER_ENGINE_SWITCH_%d", count);
  g_setenv(switch_key, "enable-impeller=false", TRUE);

  g_autofree gchar* count_value = g_strdup_printf("%d", count);
  g_setenv("FLUTTER_ENGINE_SWITCHES", count_value, TRUE);
}

int main(int argc, char** argv) {
  force_skia_renderer();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
