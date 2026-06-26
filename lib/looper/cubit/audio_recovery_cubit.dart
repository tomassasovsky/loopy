import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

part 'audio_recovery_state.dart';

/// Foot-only auto-start for the boot-with-device-absent case.
///
/// `LooperRepository`'s reconnect supervisor only arms after a *successful*
/// start, so if the console boots (or is left stopped) with its pinned USB
/// interface unplugged, nothing watches for it to come back. This cubit closes
/// that gap: given the `recoveryConfig` that auto-start attempted, it watches
/// enumeration while the engine is stopped and starts the engine the moment the
/// pinned device appears — no pointer.
///
/// It is deliberately scoped to the *never-connected* window: once audio
/// connects even once, it permanently defers to the in-repo supervisor, so the
/// two never race to restart on a transient mid-set loss.
class AudioRecoveryCubit extends Cubit<AudioRecoveryState> {
  /// Creates an [AudioRecoveryCubit].
  ///
  /// [recoveryConfig] is the pinned config a boot auto-start could not open
  /// (null when the engine started, on first run, or for the system default) —
  /// the cubit is inert when it is null or carries no pinned device. [ticker]
  /// drives the enumeration polling (a periodic timer when omitted); [interval]
  /// is that timer's period.
  AudioRecoveryCubit({
    required LooperRepository looper,
    EngineConfig? recoveryConfig,
    Stream<void>? ticker,
    Duration interval = const Duration(seconds: 2),
  }) : _looper = looper,
       _config = recoveryConfig,
       _ticker = ticker,
       _interval = interval,
       super(const AudioRecoveryState());

  final LooperRepository _looper;
  final EngineConfig? _config;
  final Stream<void>? _ticker;
  final Duration _interval;

  StreamSubscription<void>? _subscription;
  var _everConnected = false;
  var _lastPresent = false;
  var _finished = false;
  var _loaded = false;

  static bool _isPinned(EngineConfig config) =>
      config.playbackDeviceId.isNotEmpty || config.captureDeviceId.isNotEmpty;

  /// Begins watching for the pinned device (no-op when there is nothing to
  /// recover). Idempotent. The first check is deferred to the next event-loop
  /// turn so a `BlocListener` attached on the same frame still sees the initial
  /// transition.
  ///
  /// Each check enumerates devices, so the default [_interval] (2 s) is
  /// deliberately slow — unlike the repository's cheap per-poll supervisor.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final config = _config;
    if (config == null || !_isPinned(config)) return;
    _subscription = (_ticker ?? Stream<void>.periodic(_interval)).listen(
      (_) => _check(),
    );
    await Future<void>.delayed(Duration.zero);
    if (!isClosed && !_finished) _check();
  }

  void _check() {
    if (_looper.state.status.isConnected) {
      _everConnected = true;
      _finish();
      return;
    }
    // Audio ran at least once: the in-repo supervisor owns every later loss.
    if (_everConnected) {
      _finish();
      return;
    }
    final present = _pinnedPresent(_config!, _looper.devices());
    // Attempt only on the absent->present edge so a present-but-unopenable
    // device can't thrash the engine (mirrors the in-repo supervisor).
    if (present && !_lastPresent) _looper.startEngine(_config);
    _lastPresent = present;
    _emit(AudioRecoveryStatus.waitingForDevice);
  }

  void _finish() {
    _finished = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _emit(AudioRecoveryStatus.idle);
  }

  void _emit(AudioRecoveryStatus status) {
    if (isClosed || state.status == status) return;
    emit(AudioRecoveryState(status: status));
  }

  static bool _pinnedPresent(EngineConfig config, List<AudioDevice> devices) {
    bool present(String id, {required bool isInput}) =>
        id.isEmpty || devices.any((d) => d.isInput == isInput && d.id == id);
    return present(config.playbackDeviceId, isInput: false) &&
        present(config.captureDeviceId, isInput: true);
  }

  @override
  Future<void> close() {
    unawaited(_subscription?.cancel());
    return super.close();
  }
}
