import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// What a CONTINUOUS binding sweeps: one FX parameter, one track's volume, or
/// the master gain (part 7).
///
/// The discrete counterpart is part 6b's `FxBindingTarget` — a stomp flips an
/// `enabled` flag, so the two shapes address different things and stay separate
/// sealed types. Both cross the `controller_repository` boundary as
/// [canonicalString]s, which is what keeps that package free of any
/// looper/engine dependency (VGV-critical).
///
/// ## Canonical JSON
///
/// An FX param EXTENDS part 3a's [FxAddress] canonical form the same way
/// `FxSlotTarget` does (R19): the address contributes its own fixed key order,
/// then `slot` and `param`. The rig-level controls, which have no address at
/// all, use a `ctl` envelope instead. Byte-stable in every case, so plain
/// string equality is target identity.
///
/// ## One normalized domain
///
/// Every value here is `0..1` in the target's own units — built-in FX params
/// are already normalized, track volume is a `0..1` fader, master gain is
/// `0..1`. That is what lets one LO/HI pair, one knob, and one smoothing ramp
/// serve all three without the binding needing to know what it drives.
sealed class ControlValueTarget extends Equatable {
  /// Const base constructor for the sealed subtypes.
  const ControlValueTarget();

  /// Parses a [canonicalString] back to a target, or `null` when [encoded] is
  /// not a decodable one.
  ///
  /// Never throws: mappings cross app restarts as bare strings, so a corrupt or
  /// hand-edited one must decode to `null` — which the caller renders as a
  /// stale row — rather than taking the control surface down.
  static ControlValueTarget? tryParse(String encoded) {
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return null;
    }
    if (raw is! Map<String, dynamic>) return null;
    final ctl = raw['ctl'];
    if (ctl != null) {
      final index = raw['index'];
      return switch (ctl) {
        'trackVolume' when index is num && index >= 0 => TrackVolumeTarget(
          index.toInt(),
        ),
        'masterGain' => const MasterGainTarget(),
        _ => null,
      };
    }
    final address = FxAddress.fromJson(raw);
    if (address == null) return null;
    final slot = raw['slot'];
    final param = raw['param'];
    if (slot is! String || slot.isEmpty) return null;
    if (param is! num || param < 0) return null;
    return FxParamTarget(
      address: address,
      slotId: slot,
      param: param.toInt(),
    );
  }

  /// The byte-stable canonical serialization (see the class doc).
  String canonicalString();
}

/// One parameter of one effect, keyed by the part 3a stable [slotId] (A9) —
/// never by position, so inserting or reordering effects around a bound one
/// leaves the mapping pointing at the SAME effect.
///
/// [param] is the parameter's index within the effect's own descriptor list.
/// Built-in effects only in v1: a hosted plugin's parameters are addressed by
/// plugin-assigned id rather than position and have no setter at every stage,
/// so a plugin slot offers no continuous targets yet (its rows simply do not
/// appear in the picker).
final class FxParamTarget extends ControlValueTarget {
  /// Creates an FX-parameter target.
  const FxParamTarget({
    required this.address,
    required this.slotId,
    required this.param,
  });

  /// The chain the effect lives on.
  final FxAddress address;

  /// The stable per-slot id (part 3a) of the bound effect.
  final String slotId;

  /// The parameter's index within the effect type's descriptors.
  final int param;

  @override
  String canonicalString() =>
      jsonEncode({...address.toJson(), 'slot': slotId, 'param': param});

  @override
  List<Object?> get props => [address, slotId, param];
}

/// One track's volume fader.
final class TrackVolumeTarget extends ControlValueTarget {
  /// Creates a track-volume target on [channel].
  const TrackVolumeTarget(this.channel);

  /// The track channel.
  final int channel;

  @override
  String canonicalString() =>
      jsonEncode({'ctl': 'trackVolume', 'index': channel});

  @override
  List<Object?> get props => [channel];
}

/// The master output gain — the same value the pedal's encoder turns.
final class MasterGainTarget extends ControlValueTarget {
  /// Creates the master-gain target.
  const MasterGainTarget();

  @override
  String canonicalString() => jsonEncode({'ctl': 'masterGain'});

  @override
  List<Object?> get props => ['masterGain'];
}
