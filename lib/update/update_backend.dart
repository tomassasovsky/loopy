import 'package:update_repository/update_repository.dart';

/// Builds the update backend appropriate to this build.
///
/// The appliance (RAUC) and desktop (Sparkle / WinSparkle) backends land in
/// later slices; until then every platform gets the inert
/// [UnsupportedPlatformBackend], so [UpdateRepository.isSupported] is `false`
/// and the update surfaces (Settings section + startup banner) stay hidden.
/// Keeping the wiring here lets the app root stay declarative and lets a test
/// inject its own repository instead.
PlatformUpdateBackend createPlatformUpdateBackend() =>
    const UnsupportedPlatformBackend();
