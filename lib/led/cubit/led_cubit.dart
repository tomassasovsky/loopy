import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:led_client/led_client.dart';
import 'package:looper_repository/looper_repository.dart';

part 'led_state.dart';

/// Drives the Raspberry Pi console's WS2812 LEDs from looper transport state.
///
/// Mirrors `PedalCubit`'s outbound projection but for the console's own LED
/// driver: it subscribes to [LooperRepository.looperState], projects each
/// snapshot to a [LedFrame], and pushes it to the [LedRepository] (which diffs
/// and serialises). On [load] it runs the boot-time health handshake and emits
/// the result so a missing/unflashed driver surfaces as a visible fault, not
/// silent dark LEDs.
class LedCubit extends Cubit<LedState> {
  /// Creates a [LedCubit] over [led] and [looper].
  LedCubit({required LedRepository led, required LooperRepository looper})
    : _led = led,
      _looper = looper,
      super(const LedState()) {
    _subscription = _looper.looperState.listen(_onLooperState);
  }

  final LedRepository _led;
  final LooperRepository _looper;
  late final StreamSubscription<LooperState> _subscription;

  /// Runs the boot-time driver health check and pushes the initial frame.
  Future<void> load() async {
    final health = await _led.start();
    if (isClosed) return;
    emit(state.copyWith(health: health));
    _led.pushFrame(_project(_looper.state));
  }

  void _onLooperState(LooperState looperState) =>
      _led.pushFrame(_project(looperState));

  /// Projects looper transport truth to an LED frame: per-track colour by track
  /// state, a ring activity colour, and the loop length (the driver animates
  /// the position ring locally from it).
  static LedFrame _project(LooperState s) {
    final sampleRate = s.status.sampleRate;
    final lengthUs = sampleRate > 0
        ? (s.transport.masterLengthFrames * 1000000 / sampleRate).round()
        : 0;
    return LedFrame(
      running: s.transport.isRunning,
      global: _globalColor(s),
      loopLengthUs: lengthUs,
      tracks: [for (final track in s.tracks) _colorFor(track)],
    );
  }

  /// The ring activity colour: red while recording, amber while overdubbing (or
  /// mixed record+play), green while a loop plays, off when idle.
  static LedGlobalColor _globalColor(LooperState s) {
    final anyRecording = s.tracks.any((t) => t.state == TrackState.recording);
    final anyOverdub = s.tracks.any((t) => t.state == TrackState.overdubbing);
    final anyPlaying = s.tracks.any(
      (t) => t.state == TrackState.playing && !t.muted,
    );
    if (anyRecording) {
      return anyPlaying ? LedGlobalColor.amber : LedGlobalColor.red;
    }
    if (anyOverdub) return LedGlobalColor.amber;
    return anyPlaying ? LedGlobalColor.green : LedGlobalColor.off;
  }

  static LedTrackColor _colorFor(Track track) {
    if (track.muted) return LedTrackColor.off;
    return switch (track.state) {
      TrackState.recording => LedTrackColor.red,
      TrackState.overdubbing => LedTrackColor.amber,
      TrackState.playing => LedTrackColor.green,
      TrackState.empty || TrackState.stopped => LedTrackColor.off,
    };
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    _led.dispose();
    return super.close();
  }
}
