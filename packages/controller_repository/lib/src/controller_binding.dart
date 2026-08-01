import 'package:controller_repository/src/binding_behavior.dart';
import 'package:controller_repository/src/controller_input.dart';
import 'package:equatable/equatable.dart';

/// What an external MIDI control drives, in one of the two trigger shapes
/// (A10): a [ContinuousBinding] sweeping a parameter through a LO/HI range, or
/// a [DiscreteBinding] stomping a target on and off at a threshold.
///
/// ## The target is opaque here (VGV-critical)
///
/// [target] rides as a canonical-JSON STRING and is never decoded in this
/// package: that is what keeps `controller_repository` free of any
/// looper/engine dependency. The app decodes it into the typed sealed target
/// next to `ControlCubit`, which stays the single dispatch point — no second
/// control-surface interpreter grows inside a repository package.
///
/// A discrete binding's target is a part 6b `FxBindingTarget` string (the same
/// chain/slot vocabulary the pedal remap uses, so a generic MIDI footswitch
/// needs no extra plumbing); a continuous binding's target is a part 7
/// value target (FX param / track volume / master gain).
sealed class ControllerBinding extends Equatable {
  /// Const base constructor for the sealed subtypes.
  const ControllerBinding({required this.trigger, required this.target});

  /// Rebuilds a binding from its [toJson] map, or `null` when the map does not
  /// describe one (unknown/absent kind, unusable trigger, or an empty target).
  ///
  /// Never throws: the whole mapping blob crosses app restarts as text, so a
  /// corrupt or hand-edited entry must decode to `null` — dropped by
  /// `ControllerBindingSet` — rather than taking the rig's other mappings down
  /// with it.
  static ControllerBinding? fromJson(Map<String, dynamic> json) {
    final trigger = MappingTrigger.fromJson(json);
    if (trigger == null) return null;
    final target = json['target'];
    if (target is! String || target.isEmpty) return null;
    return switch (json['bind']) {
      'continuous' => ContinuousBinding(
        trigger: trigger,
        target: target,
        lo: _unit(json['lo']) ?? 0,
        hi: _unit(json['hi']) ?? 1,
      ),
      'discrete' => DiscreteBinding(
        trigger: trigger,
        target: target,
        threshold: _cc(json['threshold']) ?? DiscreteBinding.defaultThreshold,
        behavior: BindingBehavior.fromName(json['behavior'] as String?),
      ),
      _ => null,
    };
  }

  /// A `0..1` value from JSON, or `null` when absent/unusable — an
  /// out-of-range endpoint is corruption and falls back to the default rather
  /// than driving a parameter past its own domain.
  static double? _unit(Object? raw) {
    if (raw is! num) return null;
    final value = raw.toDouble();
    if (value.isNaN || value < 0 || value > 1) return null;
    return value;
  }

  /// A `0..127` CC value from JSON, or `null` when absent/unusable.
  static int? _cc(Object? raw) {
    if (raw is! num) return null;
    final value = raw.toInt();
    if (value < 0 || value > 127) return null;
    return value;
  }

  /// The control that drives this binding.
  final MappingTrigger trigger;

  /// The bound target as its canonical-JSON string (see the class doc).
  ///
  /// Kept even when it no longer resolves: a stale binding stays in the set so
  /// its row can offer rebind and clear, rather than vanishing and leaving the
  /// user to guess what they had mapped.
  final String target;

  /// The identity of this binding within a set: one binding per
  /// (control, target) pair. Fan-out (one control → many targets) and
  /// many-controls-→-one-target are both allowed; an exact repeat is not.
  (MappingTrigger, String) get key => (trigger, target);

  /// Serializes this binding to a JSON map with a fixed key order.
  Map<String, dynamic> toJson();
}

/// A continuous CC: the absolute `0..127` value maps onto `[lo, hi]`.
///
/// Both endpoints are in the target's own normalized `0..1` domain, so an
/// inverted range (`lo > hi`) is meaningful — that is how a heel-down-loud
/// expression pedal is set up — and deliberately not normalized away.
final class ContinuousBinding extends ControllerBinding {
  /// Creates a [ContinuousBinding] over `[lo, hi]` (the full domain by
  /// default).
  const ContinuousBinding({
    required super.trigger,
    required super.target,
    this.lo = 0,
    this.hi = 1,
  });

  /// The value at CC 0.
  final double lo;

  /// The value at CC 127.
  final double hi;

  /// The target value for a raw `0..127` CC [value].
  double valueFor(int value) {
    final cc = value.clamp(0, 127) / 127;
    return lo + (hi - lo) * cc;
  }

  /// Returns a copy with the given fields replaced.
  ContinuousBinding copyWith({String? target, double? lo, double? hi}) =>
      ContinuousBinding(
        trigger: trigger,
        target: target ?? this.target,
        lo: lo ?? this.lo,
        hi: hi ?? this.hi,
      );

  @override
  Map<String, dynamic> toJson() => {
    'bind': 'continuous',
    ...trigger.toJson(),
    'target': target,
    'lo': lo,
    'hi': hi,
  };

  @override
  List<Object?> get props => [trigger, target, lo, hi];
}

/// A discrete on/off CC: crossing [threshold] stomps the target, with the same
/// [BindingBehavior] vocabulary a pedal footswitch binding uses.
///
/// Edge-triggered with hysteresis (see [hysteresis]): the ON edge is
/// `value >= threshold`, the OFF edge `value < threshold - hysteresis`. A
/// controller resting exactly on the boundary, or dithering by a step or two
/// around it, therefore holds its state instead of chattering the target.
final class DiscreteBinding extends ControllerBinding {
  /// Creates a [DiscreteBinding].
  const DiscreteBinding({
    required super.trigger,
    required super.target,
    this.threshold = defaultThreshold,
    this.behavior = BindingBehavior.toggle,
  });

  /// The default ON threshold — the midpoint of the CC range, where a switch
  /// sending 0/127 and one sending 0/64 both read the same way.
  static const int defaultThreshold = 64;

  /// The lowest threshold that still describes a switch. A threshold of 0
  /// would read EVERY value as on — CC 0 included — so its off edge could
  /// never fire and a momentary bound to it would latch on with no foot on
  /// the switch, the stuck-momentary state the release-all rule (B1) exists
  /// to prevent. Enforced in [isOn] rather than the constructor so a persisted
  /// or hand-edited 0 is corrected on read too.
  static const int minThreshold = 1;

  /// How far BELOW [threshold] the value must fall to read as off.
  static const int hysteresis = 8;

  /// The CC value at or above which the control reads as on.
  final int threshold;

  /// Whether the press latches or is held.
  final BindingBehavior behavior;

  /// This binding's on/off reading of [value], given the [previous] state —
  /// unchanged inside the hysteresis band.
  ///
  /// Both edges are floored at [minThreshold]. The ON floor keeps a threshold
  /// of 0 from reading every value (CC 0 included) as on; the OFF floor keeps
  /// the release reachable for a LOW threshold, where `threshold - hysteresis`
  /// would otherwise land below 0 and no value could ever produce the off
  /// edge. Either hole leaves a momentary latched on with no foot on the
  /// switch — the stuck momentary the release-all rule (B1) exists to prevent.
  bool isOn(int value, {required bool previous}) {
    final on = threshold < minThreshold ? minThreshold : threshold;
    final off = on - hysteresis < minThreshold ? minThreshold : on - hysteresis;
    if (value >= on) return true;
    if (value < off) return false;
    return previous;
  }

  /// Returns a copy with the given fields replaced.
  DiscreteBinding copyWith({
    String? target,
    int? threshold,
    BindingBehavior? behavior,
  }) => DiscreteBinding(
    trigger: trigger,
    target: target ?? this.target,
    threshold: threshold ?? this.threshold,
    behavior: behavior ?? this.behavior,
  );

  @override
  Map<String, dynamic> toJson() => {
    'bind': 'discrete',
    ...trigger.toJson(),
    'target': target,
    'threshold': threshold,
    'behavior': behavior.name,
  };

  @override
  List<Object?> get props => [trigger, target, threshold, behavior];
}
