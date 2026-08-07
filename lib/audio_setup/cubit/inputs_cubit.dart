import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'inputs_state.dart';

/// What the player calls each hardware input, per interface.
///
/// Modelled on `TracksCubit` because it is the same problem one level down the
/// signal path: the interface says input 2 and the player says "mic". Two
/// things are NOT copies of it:
///
/// **Names belong to the DEVICE**, not to the socket number. Input 1 on a
/// Scarlett and input 1 on the built-in pair are different jacks with different
/// things plugged into them, and one name for both describes whichever rig was
/// patched last. Keyed off the engine's reported device name, the same shape
/// `latency_offset.$device.$rate.$buffer` already uses.
///
/// **There is no ceiling.** An earlier version stopped at the engine's
/// `LE_MAX_INPUTS`, on the reading that a socket past it was unusable. That
/// constant caps how many lanes one TRACK may have and which inputs can be
/// monitored — a higher-numbered channel is still recordable, so it is still
/// worth naming (#558). The list follows whatever the device reports.
///
/// One persisted map and nothing else. Provided at app level and loaded once,
/// because an input is called what the player calls it on every surface that
/// shows one — the Audio face's input chips, the Tracks routing summary and the
/// per-track lane list all read the same names through `l10n.inputName`.
class InputsCubit extends Cubit<InputsState> {
  /// Creates an [InputsCubit] that follows [repository]'s open device.
  InputsCubit({
    required SettingsRepository settings,
    required LooperRepository repository,
  }) : _settings = settings,
       _repository = repository,
       super(const InputsState()) {
    _subscription = _repository.looperState.listen(
      (looper) => unawaited(_followDevice(looper.status.deviceName)),
    );
    unawaited(_followDevice(_repository.state.status.deviceName));
  }

  final SettingsRepository _settings;
  final LooperRepository _repository;
  late final StreamSubscription<LooperState> _subscription;

  /// Sockets renamed while a load was in flight.
  ///
  /// The restore walks the sockets one await at a time, so a rename part-way
  /// through would be overwritten by the list the walk started with. Recording
  /// which sockets moved lets the restore land MERGED rather than be abandoned
  /// — dropping it wholesale would lose every OTHER socket's persisted name.
  final Set<int> _renamedDuringLoad = {};

  /// Whether a load is currently walking the sockets.
  bool _loading = false;

  /// The device a rename belongs to RIGHT NOW.
  ///
  /// Set the moment a restore starts rather than when it finishes, because
  /// [InputsState.device] cannot move until the walk has something to emit —
  /// and a rename arriving mid-walk would otherwise be saved against the
  /// device that is on its way out.
  String _device = '';

  /// Re-reads the names when the open device changes.
  ///
  /// Nothing to do while the engine reports no device: the names of the rig
  /// that is about to open are not knowable yet, and clearing the list would
  /// blank every chip for the length of a reopen. The state simply keeps the
  /// outgoing device's names until the incoming one names itself.
  Future<void> _followDevice(String device) async {
    if (device.isEmpty || device == state.device) return;
    await _restore(device);
  }

  Future<void> _restore(String device) async {
    _device = device;
    _loading = true;
    _renamedDuringLoad.clear();
    final names = <int, String>{};
    for (var input = 0; input < InputsState.probeCeiling; input++) {
      final saved = await _settings.loadInputName(device: device, input: input);
      if (saved != null && saved.isNotEmpty) names[input] = saved;
    }
    _loading = false;
    if (isClosed) return;
    // A socket renamed while this was walking keeps the name the user just
    // gave it; every other socket takes what was on disk.
    for (final input in _renamedDuringLoad) {
      final live = state.names[input];
      if (live == null || live.isEmpty) {
        names.remove(input);
      } else {
        names[input] = live;
      }
    }
    _renamedDuringLoad.clear();
    emit(InputsState(device: device, names: names));
  }

  /// Names hardware [input] on the open device, or hands the socket back its
  /// ordinal when [name] trims to nothing.
  ///
  /// An empty name is a real answer here, unlike a track's: `AUDIO /
  /// settings-rename` has no Clear button, only a backspace and Save, so
  /// emptying the field IS how an input is un-named.
  Future<void> rename(int input, String name) async {
    final device = _device;
    // Nothing to key the name to. Refused rather than stored against an empty
    // device, which would be a name that reappears on whatever opens next.
    if (device.isEmpty || input < 0) return;
    final trimmed = name.trim();
    if (trimmed == (state.names[input] ?? '')) return;
    if (_loading) _renamedDuringLoad.add(input);
    final names = {...state.names};
    if (trimmed.isEmpty) {
      names.remove(input);
    } else {
      names[input] = trimmed;
    }
    emit(state.copyWith(names: names));
    if (trimmed.isEmpty) {
      await _settings.clearInputName(device: device, input: input);
      return;
    }
    await _settings.saveInputName(device: device, input: input, name: trimmed);
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}
