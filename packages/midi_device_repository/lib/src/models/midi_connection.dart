import 'package:equatable/equatable.dart';
import 'package:midi_client/midi_client.dart';

/// The MIDI input lifecycle status, owned by the repository.
enum MidiConnectionStatus {
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

/// The most recent pinned-device connectivity transition, diffed per poll tick.
/// Mirrors the audio seam's `DeviceConnectivity`.
enum MidiConnectivity {
  /// No transition to report.
  none,

  /// The pinned device just went absent.
  lost,

  /// The pinned device just came back.
  restored,
}

/// The domain model for the MIDI input connection: the enumerated input
/// devices, the pinned selection, the live connection status, and the latest
/// hotplug transition.
///
/// This is the repository's projected domain data, not a bloc state — the
/// `MidiSetupCubit` composes it (with the raw activity stream) into its own
/// state. Independent of the audio engine.
class MidiConnection extends Equatable {
  /// Creates a [MidiConnection].
  const MidiConnection({
    this.devices = const [],
    this.selectedId = '',
    this.selectedName = '',
    this.status = MidiConnectionStatus.none,
    this.connectivity = MidiConnectivity.none,
    this.connectivityDeviceName = '',
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
  final MidiConnectionStatus status;

  /// The most recent pinned-device connectivity transition (drives the banner).
  final MidiConnectivity connectivity;

  /// Name of the device involved in the latest [connectivity] transition.
  final String connectivityDeviceName;

  /// Native result detail (e.g. result code) when [status] is
  /// [MidiConnectionStatus.error].
  final String? errorDetail;

  /// Whether a device (not "None") is pinned.
  bool get hasSelection => selectedId.isNotEmpty;

  /// Whether the pinned device is present in the current [devices] enumeration.
  bool get isSelectedPresent =>
      hasSelection && devices.any((d) => d.id == selectedId);

  /// Returns a copy with the given fields replaced.
  MidiConnection copyWith({
    List<MidiDevice>? devices,
    String? selectedId,
    String? selectedName,
    MidiConnectionStatus? status,
    MidiConnectivity? connectivity,
    String? connectivityDeviceName,
    String? errorDetail,
    bool clearError = false,
  }) {
    return MidiConnection(
      devices: devices ?? this.devices,
      selectedId: selectedId ?? this.selectedId,
      selectedName: selectedName ?? this.selectedName,
      status: status ?? this.status,
      connectivity: connectivity ?? this.connectivity,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
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
    errorDetail,
  ];
}
