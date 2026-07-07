/// Owns the performance-recording capture lifecycle for Loopy: arming and
/// disarming the audio engine, snapshotting settled lanes and monitor/master
/// state, finalizing raw PCM to WAV, and assembling the
/// `{documents}/exports/<slug>/` bundle.
library;

export 'src/models/performance_chains.dart';
export 'src/models/performance_manifest.dart';
export 'src/models/unfinalized_capture.dart';
export 'src/performance_capture_status.dart';
export 'src/performance_exception.dart';
export 'src/performance_repository.dart';
export 'src/performance_slug.dart';
