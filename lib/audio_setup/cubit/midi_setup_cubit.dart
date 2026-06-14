import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:midi_client/midi_client.dart';
import 'package:settings_repository/settings_repository.dart';

part 'midi_setup_state.dart';

/// Manages USB MIDI input-device selection for the foot-pedal control path.
///
/// Mirrors `AudioSetupCubit` for the MIDI seam, but is deliberately **fully
/// independent of the audio engine**: it never touches `LooperRepository`, so
/// switching or losing a MIDI device can never restart audio. It enumerates the
/// host's MIDI inputs, opens/closes the pinned device through the long-lived
/// [MidiControllerSource], persists the selection, and surfaces hotplug
/// lost/restored transitions (diffed per poll tick, mirroring
/// `AudioSetupCubit._detectConnectivity`).
///
/// The `source` is nullable so a build with no MIDI backend (or a test/mock
/// where the native library is absent) degrades gracefully: the picker shows
/// an empty state and selection is a no-op, rather than crashing the app.
class MidiSetupCubit extends Cubit<MidiSetupState> {
  /// Creates a [MidiSetupCubit] over [source], persisting the selection through
  /// [settings].
  ///
  /// [pollInterval] is the hotplug re-enumeration cadence; pass [Duration.zero]
  /// to disable the timer (tests drive [refresh] directly).
  MidiSetupCubit({
    required MidiControllerSource? source,
    required SettingsRepository settings,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _source = source,
       _settings = settings,
       super(const MidiSetupState()) {
    // Populate the picker immediately so it never flashes empty while the saved
    // selection loads (enumerate is a cheap synchronous native call).
    emit(MidiSetupState(devices: source?.enumerate() ?? const []));
    // Auto-reconnect the saved device on launch. The cubit is created eagerly
    // at the shell, so this is the launch reconnect — independent of the audio
    // engine's own bootstrap.
    unawaited(_hydrate());
    if (source != null && pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(pollInterval, (_) => refresh());
    }
  }

  final MidiControllerSource? _source;
  final SettingsRepository _settings;
  Timer? _pollTimer;

  /// Previous pinned-device presence, to detect lost/restored transitions.
  /// `null` until the first observation, or while nothing is pinned.
  bool? _lastSelectedPresent;

  /// The raw, pre-mapping MIDI activity stream for a UI indicator, or `null`
  /// when no MIDI backend is available.
  Stream<RawControllerInput>? get activity => _source?.activity;

  /// Loads the saved selection and reconnects it when present, tolerating a
  /// "saved device absent" launch (the selection is retained, status gone).
  Future<void> _hydrate() async {
    final source = _source;
    final saved = await _settings.loadMidiDevice();
    final devices = source?.enumerate() ?? const <MidiDevice>[];
    if (saved == null || source == null) {
      emit(state.copyWith(devices: devices, status: MidiSetupStatus.none));
      _lastSelectedPresent = null;
      return;
    }

    final present = devices.any((d) => d.id == saved.id);
    _lastSelectedPresent = present;
    if (!present) {
      emit(
        state.copyWith(
          devices: devices,
          selectedId: saved.id,
          selectedName: saved.name,
          status: MidiSetupStatus.deviceGone,
        ),
      );
      return;
    }

    final code = source.open(saved.id);
    emit(
      state.copyWith(
        devices: devices,
        selectedId: saved.id,
        selectedName: saved.name,
        status: code == 0 ? MidiSetupStatus.connected : MidiSetupStatus.error,
        errorDetail: code == 0 ? null : '$code',
        clearError: code == 0,
      ),
    );
  }

  /// Selects the device [id] to open (empty id selects "None"). Persists the
  /// choice and opens the native port now. On a failed open, sets a recoverable
  /// error status; the selection is retained so a retry / replug can recover.
  Future<void> select(String id) async {
    if (id.isEmpty) return selectNone();
    final source = _source;
    if (source == null) return;
    if (id == state.selectedId && state.status == MidiSetupStatus.connected) {
      return;
    }
    final name = _nameFor(id);
    emit(
      state.copyWith(
        selectedId: id,
        selectedName: name,
        status: MidiSetupStatus.connecting,
        connectivity: MidiConnectivity.none,
        clearError: true,
      ),
    );
    await _settings.saveMidiDevice(id: id, name: name);

    final code = source.open(id);
    _lastSelectedPresent = true;
    emit(
      code == 0
          ? state.copyWith(
              status: MidiSetupStatus.connected,
              clearError: true,
            )
          : state.copyWith(
              status: MidiSetupStatus.error,
              errorDetail: '$code',
            ),
    );
  }

  /// Deselects the device ("None"): closes the port, clears the saved keys, and
  /// stops events. The looper stays fully usable; a relaunch stays off.
  Future<void> selectNone() async {
    _source?.close();
    _lastSelectedPresent = null;
    await _settings.clearMidiDevice();
    emit(
      state.copyWith(
        selectedId: '',
        selectedName: '',
        status: MidiSetupStatus.none,
        connectivity: MidiConnectivity.none,
        clearError: true,
      ),
    );
  }

  /// Re-enumerates the host's MIDI inputs and reconciles the pinned device's
  /// connection: opens it when it (re)appears, marks it gone when it
  /// vanishes, and raises a transient lost/restored banner on the transition.
  /// Invoked by the hotplug poll timer; also callable directly (tests).
  void refresh() {
    final source = _source;
    if (source == null) return;
    final devices = source.enumerate();
    final pinned = state.hasSelection;
    final present = pinned && devices.any((d) => d.id == state.selectedId);
    final previous = _lastSelectedPresent;
    _lastSelectedPresent = pinned ? present : null;

    var next = state.copyWith(devices: devices);

    // Raise the banner on a presence transition for the pinned device only (a
    // change with no prior sample is the initial reading, not a transition).
    if (pinned && previous != null && previous != present) {
      next = next.copyWith(
        connectivity: present
            ? MidiConnectivity.restored
            : MidiConnectivity.lost,
        connectivityDeviceName: state.selectedName,
      );
    }

    if (pinned && present && state.status != MidiSetupStatus.connected) {
      // (Re)attach: launch-present, replug, or retry after an error.
      final code = source.open(state.selectedId);
      next = code == 0
          ? next.copyWith(status: MidiSetupStatus.connected, clearError: true)
          : next.copyWith(status: MidiSetupStatus.error, errorDetail: '$code');
    } else if (pinned &&
        !present &&
        state.status == MidiSetupStatus.connected) {
      // The connected device vanished: the native side stops on its own.
      next = next.copyWith(status: MidiSetupStatus.deviceGone);
    }

    emit(next);
  }

  /// The human-readable name for [id] from the current enumeration, falling
  /// back to the id itself when the device is not (yet) listed.
  String _nameFor(String id) {
    for (final device in state.devices) {
      if (device.id == id) return device.name;
    }
    return id;
  }

  @override
  Future<void> close() {
    _pollTimer?.cancel();
    // The source is owned by the ControllerRepository (it disposes it); the
    // cubit only borrows it, so it must not be disposed here.
    return super.close();
  }
}
