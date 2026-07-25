import 'dart:io';

import 'package:loopy/update/appliance/appliance_platform_backend.dart';
import 'package:update_repository/update_repository.dart';

/// Builds the update backend appropriate to this build.
///
/// On the Raspberry Pi appliance (Linux, with the baked-in marker files and
/// the `loopy-update-ctl` helper present) this is the
/// [AppliancePlatformBackend], so the update surfaces (Settings section +
/// startup banner) light up. Everywhere else — desktop (Sparkle/WinSparkle
/// land later) or a generic Linux dev build without the appliance markers —
/// it is the inert [UnsupportedPlatformBackend]; the update UI stays hidden.
PlatformUpdateBackend createPlatformUpdateBackend() {
  if (Platform.isLinux) {
    final appliance = AppliancePlatformBackend();
    if (appliance.isSupported) return appliance;
  }
  return const UnsupportedPlatformBackend();
}
