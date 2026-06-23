import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'looper_event.dart';

/// Drives the multi-track looper transport from UI and controller events, and
/// mirrors the repository's [LooperState] stream as the bloc state.
///
/// Commands are forwarded to the repository; the resulting engine state flows
/// back through the stream, keeping the repository the single source of truth.
/// When a [ControllerRepository] is supplied, its hardware-agnostic events are
/// translated into the same looper actions.
class LooperBloc extends Bloc<LooperEvent, LooperState> {
  /// Creates a [LooperBloc] backed by [repository], optionally fed by
  /// [controller] (a MIDI/GPIO foot controller).
  LooperBloc({
    required LooperRepository repository,
    ControllerRepository? controller,
    SettingsRepository? settings,
  }) : _repository = repository,
       _settings = settings,
       super(const LooperState()) {
    on<LooperStateUpdated>((event, emit) => emit(event.state));
    on<LooperRecordPressed>(
      (event, _) => _repository.record(channel: event.channel),
    );
    on<LooperStopPressed>(
      (event, _) => _repository.stopTrack(channel: event.channel),
    );
    on<LooperPlayPressed>(
      (event, _) => _repository.play(channel: event.channel),
    );
    on<LooperClearPressed>(
      (event, _) => _repository.clear(channel: event.channel),
    );
    on<LooperUndoPressed>((event, _) {
      // A track with content but no overdub layers has nothing to undo; undo
      // would be a no-op. Treat U there as "clear this track" so a single press
      // discards the lone base loop instead of doing nothing.
      if (_hasOnlyBaseLoop(event.channel)) {
        _repository.clear(channel: event.channel);
      } else {
        _repository.undo(channel: event.channel);
      }
    });
    on<LooperRedoPressed>(
      (event, _) => _repository.redo(channel: event.channel),
    );
    on<LooperVolumeChanged>(
      (event, _) => _repository.setVolume(event.volume, channel: event.channel),
    );
    on<LooperMuteToggled>(
      (event, _) => _repository.setMute(
        muted: !_isMuted(event.channel),
        channel: event.channel,
      ),
    );
    on<LooperLaneCountChanged>((event, _) {
      _repository.setLaneCount(channel: event.channel, count: event.count);
      unawaited(_settings?.saveLaneCount(event.channel, event.count));
    });
    on<LooperLaneInputChanged>((event, _) {
      _repository.setLaneInput(
        channel: event.channel,
        lane: event.lane,
        inputChannel: event.inputChannel,
      );
      unawaited(
        _settings?.saveLaneInput(event.channel, event.lane, event.inputChannel),
      );
    });
    on<LooperLaneOutputChanged>((event, _) {
      _repository.setLaneOutput(
        channel: event.channel,
        lane: event.lane,
        mask: event.mask,
      );
      unawaited(
        _settings?.saveLaneOutput(event.channel, event.lane, event.mask),
      );
    });
    on<LooperLaneVolumeChanged>((event, _) {
      _repository.setLaneVolume(
        event.volume,
        channel: event.channel,
        lane: event.lane,
      );
      unawaited(
        _settings?.saveLaneVolume(event.channel, event.lane, event.volume),
      );
    });
    on<LooperLaneMuteToggled>((event, _) {
      final muted = !_laneMuted(event.channel, event.lane);
      _repository.setLaneMute(
        muted: muted,
        channel: event.channel,
        lane: event.lane,
      );
      unawaited(
        _settings?.saveLaneMute(event.channel, event.lane, muted: muted),
      );
    });
    on<LooperLaneEffectAdded>((event, _) {
      _pushLaneEffects(event.channel, event.lane, [
        ..._repository.laneEffects(event.channel, event.lane),
        TrackEffect(type: TrackEffectType.drive),
      ]);
    });
    on<LooperLaneEffectRemoved>((event, _) {
      final effects = _repository.laneEffects(event.channel, event.lane);
      if (event.index < 0 || event.index >= effects.length) return;
      _pushLaneEffects(
        event.channel,
        event.lane,
        [...effects]..removeAt(event.index),
      );
    });
    on<LooperLaneEffectTypeChanged>((event, _) {
      final effects = _repository.laneEffects(event.channel, event.lane);
      if (event.index < 0 || event.index >= effects.length) return;
      _pushLaneEffects(
        event.channel,
        event.lane,
        [...effects]..[event.index] = TrackEffect(type: event.type),
      );
    });
    on<LooperLaneEffectMoved>((event, _) {
      final effects = _repository.laneEffects(event.channel, event.lane);
      if (event.from < 0 || event.from >= effects.length) return;
      var target = event.to;
      if (target < 0) target = 0;
      if (target > effects.length - 1) target = effects.length - 1;
      if (event.from == target) return;
      final next = [...effects];
      next.insert(target, next.removeAt(event.from));
      _pushLaneEffects(event.channel, event.lane, next);
    });
    on<LooperLaneEffectParamChanged>((event, _) {
      _repository.setLaneEffectParam(
        channel: event.channel,
        lane: event.lane,
        index: event.index,
        param: event.param,
        value: event.value,
      );
      // Re-save the whole chain (the engine call above was granular and did not
      // reset DSP; persistence stores the chain as one encoded string).
      unawaited(
        _settings?.saveLaneEffects(
          event.channel,
          event.lane,
          encodeTrackEffects(
            _repository.laneEffects(event.channel, event.lane),
          ),
        ),
      );
    });
    on<LooperTrackQuantizeChanged>((event, _) {
      _repository.setTrackQuantize(
        channel: event.channel,
        enabled: event.enabled,
      );
      unawaited(
        _settings?.saveTrackQuantize(event.channel, enabled: event.enabled),
      );
    });
    on<LooperTrackMultipleChanged>((event, _) {
      _repository.setTrackMultiple(
        channel: event.channel,
        multiple: event.multiple,
      );
      unawaited(
        _settings?.saveTrackMultiple(event.channel, event.multiple),
      );
    });
    on<LooperPlayAllPressed>((_, _) {
      for (final track in state.tracks) {
        if (track.hasContent) _repository.play(channel: track.channel);
      }
    });
    on<LooperStopAllPressed>((_, _) {
      for (final track in state.tracks) {
        _repository.stopTrack(channel: track.channel);
      }
    });
    on<LooperClearAllPressed>((_, _) {
      for (final track in state.tracks) {
        if (track.hasContent) _repository.clear(channel: track.channel);
      }
    });
    on<LooperOutputEnabledToggled>((event, _) {
      _repository.setOutputEnabled(
        output: event.output,
        enabled: event.enabled,
      );
      unawaited(
        _settings?.saveOutputEnabled(event.output, enabled: event.enabled),
      );
    });

    _subscription = _repository.looperState.listen(
      (s) => add(LooperStateUpdated(s)),
    );
    _controllerSubscription = controller?.events.listen(_onControllerEvent);
  }

  final LooperRepository _repository;
  final SettingsRepository? _settings;
  late final StreamSubscription<LooperState> _subscription;
  StreamSubscription<ControllerEvent>? _controllerSubscription;

  bool _isMuted(int channel) =>
      channel >= 0 &&
      channel < state.tracks.length &&
      state.tracks[channel].muted;

  /// Whether [channel] holds a single recorded loop with no overdub layers to
  /// undo — the case where `U` clears the track instead of removing a layer.
  bool _hasOnlyBaseLoop(int channel) {
    if (channel < 0 || channel >= state.tracks.length) return false;
    final track = state.tracks[channel];
    return track.hasContent && !track.canUndo;
  }

  bool _laneMuted(int channel, int lane) {
    if (channel < 0 || channel >= state.tracks.length) return false;
    final lanes = state.tracks[channel].lanes;
    return lane >= 0 && lane < lanes.length && lanes[lane].muted;
  }

  /// Pushes a freshly-computed lane chain to the engine and persists it. The
  /// single home for lane FX structural edits — every add/remove/retype/move
  /// handler routes here so the chain surgery lives in one place, never the UI.
  void _pushLaneEffects(int channel, int lane, List<TrackEffect> effects) {
    _repository.setLaneEffects(channel: channel, lane: lane, effects: effects);
    unawaited(
      _settings?.saveLaneEffects(channel, lane, encodeTrackEffects(effects)),
    );
  }

  void _onControllerEvent(ControllerEvent event) {
    switch (event.action) {
      case LooperAction.recordOverdub:
        add(LooperRecordPressed(event.channel));
      case LooperAction.stop:
        add(LooperStopPressed(event.channel));
      case LooperAction.play:
        add(LooperPlayPressed(event.channel));
      case LooperAction.clear:
        add(LooperClearPressed(event.channel));
      case LooperAction.undo:
        add(LooperUndoPressed(event.channel));
      case LooperAction.playAll:
        add(const LooperPlayAllPressed());
      case LooperAction.stopAll:
        add(const LooperStopAllPressed());
    }
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    unawaited(_controllerSubscription?.cancel());
    return super.close();
  }
}
