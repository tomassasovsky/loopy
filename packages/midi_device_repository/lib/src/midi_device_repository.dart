import 'dart:async';

import 'package:midi_client/midi_client.dart';
import 'package:midi_device_repository/src/models/midi_connection.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the MIDI input (foot-controller) device lifecycle and is the single
/// source of MIDI-device truth in the data layer.
///
/// Mirrors `LooperRepository` for the MIDI seam, but is deliberately **fully
/// independent of the audio engine**: it never touches `LooperRepository`, so
/// switching or losing a MIDI device can never restart audio. It enumerates the
/// host's MIDI inputs, opens/closes the pinned device through the long-lived
/// [MidiControllerSource], persists the selection, and supervises hotplug
/// lost/restored transitions (diffed per poll tick). The projected
/// [MidiConnection] domain model is published on [connections]; the raw
/// (pre-mapping) input is republished on [activity]. Commands ([select],
/// [selectNone], [refresh]) drive the lifecycle.
///
/// The `source` is nullable so a build with no MIDI backend (or a test/mock
/// where the native library is absent) degrades gracefully: the picker shows an
/// empty state and selection is a no-op, rather than crashing the app.
///
/// **Disposal contract:** the source is *borrowed*. `ControllerRepository` owns
/// it and disposes it; this repository must never dispose it — [dispose] only
/// releases its own timer and stream.
class MidiDeviceRepository {
  /// Creates a [MidiDeviceRepository] over [source], persisting the selection
  /// through [settings].
  ///
  /// [pollInterval] is the hotplug re-enumeration cadence; pass [Duration.zero]
  /// to disable the timer (tests drive [refresh] directly).
  MidiDeviceRepository({
    required MidiControllerSource? source,
    required SettingsRepository settings,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _source = source,
       _settings = settings {
    // Populate the picker immediately so it never flashes empty while the saved
    // selection loads (enumerate is a cheap synchronous native call).
    _emit(MidiConnection(devices: source?.enumerate() ?? const []));
    // Auto-reconnect the saved device on launch. The repository is created
    // eagerly at the shell, so this is the launch reconnect — independent of
    // the audio engine's own bootstrap.
    unawaited(_hydrate());
    if (source != null && pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(pollInterval, (_) => refresh());
    }
  }

  final MidiControllerSource? _source;
  final SettingsRepository _settings;
  final StreamController<MidiConnection> _controller =
      StreamController<MidiConnection>.broadcast();
  Timer? _pollTimer;

  MidiConnection _connection = const MidiConnection();

  /// Previous pinned-device presence, to detect lost/restored transitions.
  /// `null` until the first observation, or while nothing is pinned.
  bool? _lastSelectedPresent;

  /// The current connection, read synchronously.
  MidiConnection get connection => _connection;

  /// Stream of MIDI-input connection states.
  ///
  /// A new subscriber immediately receives the most recent connection before
  /// live updates, so a late listener — e.g. a cubit created after the launch
  /// reconnect already ran — shows the current selection instead of waiting for
  /// the next change.
  Stream<MidiConnection> get connections async* {
    yield _connection;
    yield* _controller.stream;
  }

  /// The raw (pre-mapping) MIDI activity, republished from the borrowed source
  /// for a UI input indicator. Empty when no MIDI backend is present.
  Stream<void> get activity =>
      _source?.activity.map((_) {}) ?? const Stream<void>.empty();

  void _emit(MidiConnection next) {
    _connection = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// Loads the saved selection and reconnects it when present, tolerating a
  /// "saved device absent" launch (the selection is retained, status gone).
  Future<void> _hydrate() async {
    final source = _source;
    final saved = await _settings.loadMidiDevice();
    final devices = source?.enumerate() ?? const <MidiDevice>[];
    if (saved == null || source == null) {
      _emit(_connection.copyWith(devices: devices));
      _lastSelectedPresent = null;
      return;
    }

    final present = devices.any((d) => d.id == saved.id);
    _lastSelectedPresent = present;
    if (!present) {
      _emit(
        _connection.copyWith(
          devices: devices,
          selectedId: saved.id,
          selectedName: saved.name,
          status: MidiConnectionStatus.deviceGone,
        ),
      );
      return;
    }

    final code = source.open(saved.id);
    _emit(
      _connection.copyWith(
        devices: devices,
        selectedId: saved.id,
        selectedName: saved.name,
        status: code == 0
            ? MidiConnectionStatus.connected
            : MidiConnectionStatus.error,
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
    if (id == _connection.selectedId &&
        _connection.status == MidiConnectionStatus.connected) {
      return;
    }
    final name = _nameFor(id);
    _emit(
      _connection.copyWith(
        selectedId: id,
        selectedName: name,
        status: MidiConnectionStatus.connecting,
        connectivity: MidiConnectivity.none,
        clearError: true,
      ),
    );
    await _settings.saveMidiDevice(id: id, name: name);

    final code = source.open(id);
    _lastSelectedPresent = true;
    _emit(
      code == 0
          ? _connection.copyWith(
              status: MidiConnectionStatus.connected,
              clearError: true,
            )
          : _connection.copyWith(
              status: MidiConnectionStatus.error,
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
    _emit(
      _connection.copyWith(
        selectedId: '',
        selectedName: '',
        status: MidiConnectionStatus.none,
        connectivity: MidiConnectivity.none,
        clearError: true,
      ),
    );
  }

  /// Re-enumerates the host's MIDI inputs and reconciles the pinned device's
  /// connection: opens it when it (re)appears, marks it gone when it
  /// vanishes, and raises a transient lost/restored transition on the change.
  /// Invoked by the hotplug poll timer; also callable directly (tests).
  void refresh() {
    final source = _source;
    if (source == null) return;
    final devices = source.enumerate();
    final pinned = _connection.hasSelection;
    final present =
        pinned && devices.any((d) => d.id == _connection.selectedId);
    final previous = _lastSelectedPresent;
    _lastSelectedPresent = pinned ? present : null;

    var next = _connection.copyWith(devices: devices);

    // Raise the transition for the pinned device only (a change with no prior
    // sample is the initial reading, not a transition).
    if (pinned && previous != null && previous != present) {
      next = next.copyWith(
        connectivity: present
            ? MidiConnectivity.restored
            : MidiConnectivity.lost,
        connectivityDeviceName: _connection.selectedName,
      );
    }

    if (pinned &&
        present &&
        _connection.status != MidiConnectionStatus.connected) {
      // (Re)attach: launch-present, replug, or retry after an error.
      final code = source.open(_connection.selectedId);
      next = code == 0
          ? next.copyWith(
              status: MidiConnectionStatus.connected,
              clearError: true,
            )
          : next.copyWith(
              status: MidiConnectionStatus.error,
              errorDetail: '$code',
            );
    } else if (pinned &&
        !present &&
        _connection.status == MidiConnectionStatus.connected) {
      // The connected device vanished: the native side stops on its own.
      next = next.copyWith(status: MidiConnectionStatus.deviceGone);
    }

    _emit(next);
  }

  /// The human-readable name for [id] from the current enumeration, falling
  /// back to the id itself when the device is not (yet) listed.
  String _nameFor(String id) {
    for (final device in _connection.devices) {
      if (device.id == id) return device.name;
    }
    return id;
  }

  /// Releases the timer and the connection stream.
  ///
  /// The [MidiControllerSource] is **borrowed**, not owned:
  /// `ControllerRepository` disposes it. This must never dispose it (or it
  /// would tear down the shared input capture out from under the controller
  /// pipeline).
  Future<void> dispose() async {
    _pollTimer?.cancel();
    await _controller.close();
  }
}
