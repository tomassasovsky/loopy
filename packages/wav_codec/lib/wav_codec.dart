/// A minimal 32-bit IEEE-float WAV encoder/decoder.
///
/// `WavCodec` is the lossless format Loopy stores its loop stems, mixdowns,
/// and performance-recording exports in. Pure Dart — no Flutter dependency —
/// so tooling that must not depend on the framework (e.g. `daw_export`) can
/// still read the files this writes.
library;

export 'src/wav.dart';
