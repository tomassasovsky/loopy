import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

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
  }) : _repository = repository,
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
    on<LooperUndoPressed>(
      (event, _) => _repository.undo(channel: event.channel),
    );
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

    _subscription = _repository.looperState.listen(
      (s) => add(LooperStateUpdated(s)),
    );
    _controllerSubscription = controller?.events.listen(_onControllerEvent);
  }

  final LooperRepository _repository;
  late final StreamSubscription<LooperState> _subscription;
  StreamSubscription<ControllerEvent>? _controllerSubscription;

  bool _isMuted(int channel) =>
      channel >= 0 &&
      channel < state.tracks.length &&
      state.tracks[channel].muted;

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
