part of 'pedal_cubit.dart';

/// Sentinel for [PedalState.copyWith] so a `null` [PedalState.boundOutputId]
/// (unbound) can be set explicitly while omitting it preserves the current id.
const Object _unsetBoundOutputId = Object();

/// Sentinel for [PedalState.copyWith] so a `null`
/// [PedalState.firmwareVersion] (unknown) can be set explicitly while
/// omitting it preserves the current value.
const Object _unsetFirmwareVersion = Object();

/// The pedal LINK state: everything about the physical (or simulated) pedal's
/// transport binding, and nothing else.
///
/// The control overlay (mode, cursor, bank, play intent) lives in
/// `ControlOverlayCubit`; the looper transport/track truth in `LooperState`;
/// the LEDs are a pure projection of the two (`control_projection.dart`).
/// This cubit's state is only the output-device plumbing the settings picker
/// renders.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.bindStatus = PedalBindStatus.none,
    this.availableOutputs = const [],
    this.boundOutputId,
    this.firmwareVersion,
    this.firmwareUpdateAvailable = false,
  });

  /// The pedal output link status, mirrored for the settings UI.
  final PedalBindStatus bindStatus;

  /// The host's currently enumerated MIDI output destinations, refreshed on
  /// hotplug so the settings picker stays current.
  final List<PedalOutput> availableOutputs;

  /// The id of the currently bound output destination, or `null` when unbound.
  final String? boundOutputId;

  /// The manually-set pedal firmware wire-protocol version, or `null` when
  /// unknown (the default) — the pre-#331 version-discovery gate (R6).
  /// Unknown keeps outbound frames at the v2 safety floor, never v3.
  final int? firmwareVersion;

  /// Whether a REAL bound pedal negotiates below the newest protocol, so the
  /// codec is downgrading what loopy sends it (flow err-4: FX mode arrives as
  /// mute, chain LEDs as green).
  ///
  /// DERIVED in the cubit from `PedalRepository.targetProtocolVersion` — the
  /// one place the unknown-to-v2 floor and the on-screen-pedal carve-out are
  /// decided — so the banner cannot drift from what is actually on the wire
  /// when #331's identity-reply discovery replaces the manual gate.
  final bool firmwareUpdateAvailable;

  /// Returns a copy with the given fields replaced.
  PedalState copyWith({
    PedalBindStatus? bindStatus,
    List<PedalOutput>? availableOutputs,
    Object? boundOutputId = _unsetBoundOutputId,
    Object? firmwareVersion = _unsetFirmwareVersion,
    bool? firmwareUpdateAvailable,
  }) {
    return PedalState(
      bindStatus: bindStatus ?? this.bindStatus,
      availableOutputs: availableOutputs ?? this.availableOutputs,
      boundOutputId: identical(boundOutputId, _unsetBoundOutputId)
          ? this.boundOutputId
          : boundOutputId as String?,
      firmwareVersion: identical(firmwareVersion, _unsetFirmwareVersion)
          ? this.firmwareVersion
          : firmwareVersion as int?,
      firmwareUpdateAvailable:
          firmwareUpdateAvailable ?? this.firmwareUpdateAvailable,
    );
  }

  @override
  List<Object?> get props => [
    bindStatus,
    availableOutputs,
    boundOutputId,
    firmwareVersion,
    firmwareUpdateAvailable,
  ];
}
