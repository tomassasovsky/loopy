import 'package:session_repository/session_repository.dart';

/// Typed failures a session load can raise, so callers can present a
/// human-readable, localized message instead of a raw `toString()`.
///
/// These are the recoverable, user-facing refusals (the engine is fine; the
/// chosen bundle simply can't be loaded as-is). Lower-level I/O failures and
/// engine errors surface as their native exception types.
sealed class SessionException implements Exception {
  const SessionException();
}

/// The session was recorded at a sample rate that differs from the running
/// device's. Loading its raw stems would play them back at the wrong pitch
/// (there is no resampling), so [SessionRepository.load] refuses.
class SessionSampleRateMismatch extends SessionException {
  /// Creates a [SessionSampleRateMismatch].
  const SessionSampleRateMismatch({
    required this.sessionRate,
    required this.deviceRate,
  });

  /// The sample rate the session was recorded at, in Hz.
  final int sessionRate;

  /// The running device's sample rate, in Hz.
  final int deviceRate;

  @override
  String toString() =>
      'session sample rate $sessionRate Hz does not match the device rate '
      '$deviceRate Hz';
}

/// The session manifest was written by a newer, incompatible schema [version]
/// than this build understands (it [supported] up to a lower version).
class SessionUnsupportedVersion extends SessionException {
  /// Creates a [SessionUnsupportedVersion].
  const SessionUnsupportedVersion({
    required this.version,
    required this.supported,
  });

  /// The manifest's declared schema version.
  final int version;

  /// The highest schema version this build can read.
  final int supported;

  @override
  String toString() =>
      'unsupported session version $version (supports up to $supported)';
}
