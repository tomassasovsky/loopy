/// Platform-agnostic software-update domain: the manifest, a pluggable platform
/// backend (appliance RAUC / desktop Sparkle), and the check/stage/apply
/// orchestration the app's UpdateCubit drives.
library;

export 'package:pub_semver/pub_semver.dart' show Version;

export 'src/platform_update_backend.dart' show PlatformUpdateBackend;
export 'src/unsupported_platform_backend.dart' show UnsupportedPlatformBackend;
export 'src/update_channel.dart' show normalizeUpdateChannel;
export 'src/update_manifest.dart' show UpdateManifest;
export 'src/update_repository.dart' show UpdateRepository;
