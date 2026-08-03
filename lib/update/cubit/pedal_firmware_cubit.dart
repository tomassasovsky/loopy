import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:update_repository/update_repository.dart';

/// Where the post-reboot pedal flash has got to.
enum PedalFirmwareStage {
  /// Asking the helper whether a flash is coming. Nothing is shown yet: this
  /// resolves in milliseconds on desktop and must not flash a screen.
  checking,

  /// Nothing to do — no firmware published, pedal already current, or no pedal.
  /// The looper is free to run.
  idle,

  /// Programming. The pedal is in its bootloader for the duration.
  flashing,

  /// The flash did not complete. The user is let through anyway.
  failed,
}

/// State of the pedal firmware gate.
class PedalFirmwareState extends Equatable {
  /// Creates a [PedalFirmwareState].
  const PedalFirmwareState({
    this.stage = PedalFirmwareStage.checking,
    this.version,
    this.progress = 0,
    this.error,
  });

  /// Where the flash has got to.
  final PedalFirmwareStage stage;

  /// The firmware version being written, when known.
  final String? version;

  /// Flash progress in `[0, 1]`.
  final double progress;

  /// Why the flash failed, when it did.
  final String? error;

  /// Whether the looper should be covered.
  bool get blocksLooper =>
      stage == PedalFirmwareStage.flashing ||
      stage == PedalFirmwareStage.failed;

  @override
  List<Object?> get props => [stage, version, progress, error];
}

/// Runs the pedal firmware flash that an OS update left pending, and holds the
/// UI closed while it does.
///
/// The flash cannot run during the OS update itself — that code lives in the
/// image being replaced, so it would run the outgoing flasher (#444). Doing it
/// here, on the next start, means the flasher that runs is the one that shipped
/// with the running image.
///
/// It is blocking on purpose. A pedal being programmed sits in its Caterina
/// bootloader: the footswitches do nothing and the ring is dark. A user left in
/// the looper does not read that as an update, they read it as a dead pedal —
/// and if they are playing, it is one.
class PedalFirmwareCubit extends Cubit<PedalFirmwareState> {
  /// Creates a [PedalFirmwareCubit] over [updates].
  PedalFirmwareCubit({required UpdateRepository updates})
    : _updates = updates,
      super(const PedalFirmwareState());

  final UpdateRepository _updates;

  /// Flashes the pending firmware, if any. Safe to call once per app start.
  Future<void> run() async {
    if (!_updates.isSupported) {
      emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
      return;
    }

    final version = await _updates.pendingPedalFirmware();
    if (isClosed) return;
    if (version == null) {
      emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
      return;
    }

    emit(
      PedalFirmwareState(stage: PedalFirmwareStage.flashing, version: version),
    );
    try {
      await for (final progress in _updates.flashPedalFirmware()) {
        if (isClosed) return;
        emit(
          PedalFirmwareState(
            stage: PedalFirmwareStage.flashing,
            version: version,
            progress: progress.clamp(0.0, 1.0),
          ),
        );
      }
      if (isClosed) return;
      emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
    } on Exception catch (error) {
      if (isClosed) return;
      emit(
        PedalFirmwareState(
          stage: PedalFirmwareStage.failed,
          version: version,
          error: '$error',
        ),
      );
    }
  }

  /// Dismisses a failure and lets the user into the looper. The pedal keeps its
  /// old firmware and the next start will offer the flash again.
  void dismiss() =>
      emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
}
