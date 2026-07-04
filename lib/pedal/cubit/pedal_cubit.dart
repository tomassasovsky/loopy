import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'pedal_state.dart';

/// The pedal LINK feature: binds the MIDI output device, keeps it bound
/// across hotplugs, and surfaces the picker state ([PedalState]) for the
/// settings UI. Nothing else.
///
/// The pedal's BEHAVIOR — decoding footswitch events into intents and
/// pushing projected LED frames — is `ControlCubit`'s job: both cubits sit
/// on the shared [PedalRepository] (events in / frames out for control,
/// binding for this one) and know nothing about each other.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  PedalCubit({
    required PedalRepository pedal,
    required SettingsRepository settings,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _pedal = pedal,
       _settings = settings,
       super(const PedalState()) {
    _statusSub = _pedal.statusChanges.listen(_onBindStatus);
    // Seed the output set so the settings picker has it before the first
    // poll.
    _syncOutputs();
    // Hotplug auto-reconnect for the bound output (mirrors MidiSetupCubit).
    // Pass Duration.zero to disable the timer (tests drive [reconnect]).
    if (pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(pollInterval, (_) => reconnect());
    }
  }

  final PedalRepository _pedal;
  final SettingsRepository _settings;

  late final StreamSubscription<PedalBindStatus> _statusSub;

  // Hotplug reconnect for the bound output: the pinned device id and the poll
  // timer that re-binds it when it (re)appears. The enumerated set + bound id
  // live in PedalState (see _syncOutputs); Equatable dedups no-op refreshes.
  Timer? _pollTimer;
  String? _savedOutputId;

  Future<void>? _loadFuture;

  /// Loads the persisted pedal output and auto-binds it. (The boot-default
  /// MODE and the undo long-press threshold are control state, restored by
  /// `ControlCubit.load`.)
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final saved = await _settings.loadPedalOutputDevice();
    if (saved == null) return;
    // Pin the saved output so the poll can reconnect it; bind now if present,
    // otherwise the poll binds it as soon as it appears.
    _savedOutputId = saved.id;
    if (_pedal.availableOutputs().any((d) => d.id == saved.id)) {
      _pedal.bind(saved.id);
    }
    _syncOutputs();
  }

  /// Folds the host's enumerated MIDI outputs and the bound destination into
  /// [PedalState], so the settings picker reads them from state rather than
  /// via read-through accessors. Equatable dedups when nothing changed.
  void _syncOutputs() {
    if (isClosed) return;
    emit(
      state.copyWith(
        availableOutputs: _pedal.availableOutputs(),
        boundOutputId: _pedal.boundOutputId,
      ),
    );
  }

  /// Binds the pedal output to [device] and persists the choice.
  Future<void> selectOutput(PedalOutput device) async {
    _savedOutputId = device.id;
    _pedal.bind(device.id);
    _syncOutputs();
    await _settings.savePedalOutputDevice(id: device.id, name: device.name);
  }

  /// Unbinds the pedal output and clears the saved device.
  Future<void> selectNone() async {
    _savedOutputId = null;
    _pedal.unbind();
    _syncOutputs();
    await _settings.clearPedalOutputDevice();
    if (!isClosed) emit(state.copyWith(boundOutputId: null));
  }

  /// Hotplug poll: re-enumerates the host's MIDI outputs and reconciles the
  /// pinned pedal output — (re)binds it when it appears (launch, replug, or a
  /// retry after a failed open) and drops the stale handle when it vanishes,
  /// so the LED-feedback link survives unplugs without relaunching loopy.
  /// Mirrors `MidiSetupCubit.refresh`; runs on the poll timer and is callable
  /// directly.
  void reconnect() {
    if (isClosed) return;
    final outputs = _pedal.availableOutputs();
    final saved = _savedOutputId;
    if (saved != null) {
      final present = outputs.any((d) => d.id == saved);
      if (present && _pedal.boundOutputId != saved) {
        _pedal.bind(saved); // (re)connect on appear / replug / retry
      } else if (!present && _pedal.boundOutputId == saved) {
        _pedal.unbind(); // pinned device vanished: drop the stale port handle
      }
    }
    // Reflect the (possibly changed) output set + bound id into state; the
    // settings picker re-renders only when one of them actually changed.
    _syncOutputs();
  }

  void _onBindStatus(PedalBindStatus status) {
    if (isClosed) return;
    emit(state.copyWith(bindStatus: status));
  }

  @override
  Future<void> close() async {
    _pollTimer?.cancel();
    await _statusSub.cancel();
    // Darken the pedal on shutdown (no-op when not bound), then release the
    // transport — this cubit is the pedal repository's lifecycle owner.
    _pedal.pushState(PedalStateFrame.blank(goodbye: true));
    await _pedal.dispose();
    return super.close();
  }
}
