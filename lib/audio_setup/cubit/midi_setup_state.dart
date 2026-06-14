part of 'midi_setup_cubit.dart';

/// The MIDI input lifecycle status, surfaced by the picker as a status line.
enum MidiSetupStatus {
  /// No device is selected; the looper runs without MIDI.
  none,

  /// A device was selected and the native port is being opened.
  connecting,

  /// The selected device is open and delivering input.
  connected,

  /// Opening the selected device failed (e.g. it is in use by another app).
  /// The selection is retained so a later retry / replug can recover.
  error,

  /// The selected device is not currently present (unplugged, or absent at
  /// launch). The selection is retained; a later replug auto-reconnects.
  deviceGone,
}

/// The most recent pinned-device connectivity transition, used to drive a
/// transient connect/disconnect banner. Derived in the cubit by diffing device
/// presence per poll tick; mirrors the audio setup's `DeviceConnectivity`.
enum MidiConnectivity {
  /// No transition to report.
  none,

  /// The pinned device just went absent.
  lost,

  /// The pinned device just came back.
  restored,
}

/// State for the MIDI setup feature: the enumerated input devices, the pinned
/// selection, and the live connection status. Independent of the audio engine.
class MidiSetupState extends Equatable {
  /// Creates a [MidiSetupState].
  const MidiSetupState({
    this.devices = const [],
    this.selectedId = '',
    this.selectedName = '',
    this.status = MidiSetupStatus.none,
    this.connectivity = MidiConnectivity.none,
    this.connectivityDeviceName = '',
    this.activityTick = 0,
    this.errorDetail,
  });

  /// The host's enumerated MIDI input devices, for the picker.
  final List<MidiDevice> devices;

  /// The pinned device id, or empty for "None" (no device).
  final String selectedId;

  /// The pinned device name, kept so a "last device not found" status can name
  /// the device even while it is absent from [devices].
  final String selectedName;

  /// High-level lifecycle status.
  final MidiSetupStatus status;

  /// The most recent pinned-device connectivity transition (drives the banner).
  final MidiConnectivity connectivity;

  /// Name of the device involved in the latest [connectivity] transition.
  final String connectivityDeviceName;

  /// A monotonically increasing counter bumped on every raw (pre-mapping) MIDI
  /// message, so the activity indicator can blink without the cubit exposing a
  /// stream. The value itself is meaningless; only its changes matter.
  final int activityTick;

  /// Native result detail (e.g. result name) when [status] is
  /// [MidiSetupStatus.error].
  final String? errorDetail;

  /// Whether a device (not "None") is pinned.
  bool get hasSelection => selectedId.isNotEmpty;

  /// Whether the pinned device is present in the current [devices] enumeration.
  bool get isSelectedPresent =>
      hasSelection && devices.any((d) => d.id == selectedId);

  /// Returns a copy with the given fields replaced.
  MidiSetupState copyWith({
    List<MidiDevice>? devices,
    String? selectedId,
    String? selectedName,
    MidiSetupStatus? status,
    MidiConnectivity? connectivity,
    String? connectivityDeviceName,
    int? activityTick,
    String? errorDetail,
    bool clearError = false,
  }) {
    return MidiSetupState(
      devices: devices ?? this.devices,
      selectedId: selectedId ?? this.selectedId,
      selectedName: selectedName ?? this.selectedName,
      status: status ?? this.status,
      connectivity: connectivity ?? this.connectivity,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
      activityTick: activityTick ?? this.activityTick,
      // [clearError] resets the detail on a successful open, since a nullable
      // field cannot otherwise be cleared through `?? this`.
      errorDetail: clearError ? null : (errorDetail ?? this.errorDetail),
    );
  }

  @override
  List<Object?> get props => [
    devices,
    selectedId,
    selectedName,
    status,
    connectivity,
    connectivityDeviceName,
    activityTick,
    errorDetail,
  ];
}
