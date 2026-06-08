import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart';

part 'duplex_smoke_state.dart';

/// Drives the Phase-1 duplex passthrough smoke harness.
///
/// Owns an [AudioEngine], starts a duplex passthrough stream, and polls the
/// engine snapshot on a render-rate timer so the view can show live levels,
/// frame counters, and round-trip latency. This is a temporary harness; the
/// looper repository replaces direct engine ownership in Phase 2.
class DuplexSmokeCubit extends Cubit<DuplexSmokeState> {
  /// Creates a [DuplexSmokeCubit] driving the given `engine`.
  ///
  /// [pollInterval] controls how often the engine snapshot is read while
  /// running (defaults to ~60 Hz).
  DuplexSmokeCubit(
    this._engine, {
    Duration pollInterval = const Duration(milliseconds: 16),
  }) : _pollInterval = pollInterval,
       super(const DuplexSmokeState());

  final AudioEngine _engine;
  final Duration _pollInterval;
  Timer? _pollTimer;

  /// The engine + miniaudio version string.
  String get engineVersion => _engine.version;

  /// Starts duplex passthrough and begins polling the snapshot.
  void start({EngineConfig config = const EngineConfig(passthrough: true)}) {
    if (state.status == DuplexSmokeStatus.running) return;

    final result = _engine.start(config);
    if (!result.isOk) {
      emit(
        state.copyWith(
          status: DuplexSmokeStatus.error,
          errorMessage: 'start failed: ${result.name}',
        ),
      );
      return;
    }

    emit(
      DuplexSmokeState(
        status: DuplexSmokeStatus.running,
        snapshot: _engine.snapshot(),
        deviceName: _engine.deviceName,
      ),
    );
    _pollTimer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  /// Stops the engine and snapshot polling.
  void stop() {
    if (state.status != DuplexSmokeStatus.running) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    _engine.stop();
    emit(const DuplexSmokeState());
  }

  /// Reads the latest engine snapshot and emits it. Called by the poll timer;
  /// also exposed for manual refresh and deterministic testing.
  void refresh() {
    if (state.status != DuplexSmokeStatus.running) return;
    emit(state.copyWith(snapshot: _engine.snapshot()));
  }

  /// Triggers a single loopback round-trip latency measurement.
  void measureLatency() {
    if (state.status != DuplexSmokeStatus.running) return;
    _engine.measureLatency();
  }

  @override
  Future<void> close() {
    _pollTimer?.cancel();
    _engine.dispose();
    return super.close();
  }
}
