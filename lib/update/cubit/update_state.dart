part of 'update_cubit.dart';

/// Where the update flow currently is.
enum UpdatePhase {
  /// Nothing in progress; no check has run (or the platform is unsupported).
  idle,

  /// A read-only availability check is running.
  checking,

  /// The last check found the device on the newest published build.
  upToDate,

  /// A newer build is available and not yet staged.
  available,

  /// The available bundle is downloading/staging to the inactive slot.
  downloading,

  /// A newer build is fully staged and awaiting a restart to apply.
  staged,

  /// The last operation failed; see [UpdateState.errorMessage].
  error,
}

/// Immutable state of the update feature.
@immutable
class UpdateState extends Equatable {
  /// Creates an [UpdateState].
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.supported = false,
    this.channel = '',
    this.currentVersion = 0,
    this.available,
    this.progress = 0,
    this.autoCheck = true,
    this.dismissed = const {},
    this.errorMessage,
  });

  /// The current phase of the flow.
  final UpdatePhase phase;

  /// Whether in-app updates are offered on this platform.
  final bool supported;

  /// The channel this device follows, for display.
  final String channel;

  /// The running build number (`0` when unknown).
  final int currentVersion;

  /// The newer manifest found by the last check, or `null` if none.
  final UpdateManifest? available;

  /// Download/stage progress in `[0, 1]`, meaningful in [UpdatePhase.downloading].
  final double progress;

  /// Whether the passive, read-only check runs automatically.
  final bool autoCheck;

  /// Build numbers the user dismissed the notification for; a newer version
  /// re-notifies because it is not in this set.
  final Set<int> dismissed;

  /// A human-readable message when [phase] is [UpdatePhase.error].
  final String? errorMessage;

  /// Whether a newer build is currently on offer (available or staged).
  bool get hasUpdate => available != null;

  /// Whether the startup banner should be shown: an update is available and its
  /// version has not been dismissed.
  bool get shouldNotify =>
      available != null && !dismissed.contains(available!.version);

  /// Copies this state, overriding the given fields. Set [clearAvailable] to
  /// drop the available manifest (there is no other way to null it), and
  /// [clearError] to clear a previous error message.
  UpdateState copyWith({
    UpdatePhase? phase,
    bool? supported,
    String? channel,
    int? currentVersion,
    UpdateManifest? available,
    bool clearAvailable = false,
    double? progress,
    bool? autoCheck,
    Set<int>? dismissed,
    String? errorMessage,
    bool clearError = false,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      supported: supported ?? this.supported,
      channel: channel ?? this.channel,
      currentVersion: currentVersion ?? this.currentVersion,
      available: clearAvailable ? null : (available ?? this.available),
      progress: progress ?? this.progress,
      autoCheck: autoCheck ?? this.autoCheck,
      dismissed: dismissed ?? this.dismissed,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  @override
  List<Object?> get props => [
    phase,
    supported,
    channel,
    currentVersion,
    available,
    progress,
    autoCheck,
    dismissed,
    errorMessage,
  ];
}
