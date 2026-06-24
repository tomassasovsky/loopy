import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_knob.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The settle "pop" a dragged device card plays as it lands — it arrives
/// slightly enlarged and springs down to rest. Deliberately overshoots, which
/// the Material 3 [Easing] set never does, so it stays a named [Curves] value
/// rather than an M3 motion token.
const Curve _dropSettleCurve = Curves.easeOutBack;

/// How many of a hosted plugin's parameters get an in-app knob on its device
/// card (D-UI). The rest live in the plugin's own editor window (part 6); this
/// is a UI affordance cap, not an engine limit.
const int kPluginKnobs = 4;

/// An **Ableton-style FX rack**: the chain laid out as horizontal **device
/// cards**, each showing its type and its parameters as live knobs — rather
/// than a chip list with one editor at a time. Shared by both docks.
class SignalFxRack extends StatefulWidget {
  /// Creates a [SignalFxRack].
  const SignalFxRack({
    required this.keyPrefix,
    required this.effects,
    required this.onAddEffect,
    required this.onRemoveEffect,
    required this.onSetType,
    required this.onSetParam,
    required this.onSetPluginParam,
    required this.onOpenPluginEditor,
    required this.onRelinkPlugin,
    required this.onReorder,
    super.key,
  });

  /// Selector namespace (`signalGraph_input` / `signalGraph_lane`).
  final String keyPrefix;

  /// The chain, in processing order.
  final List<TrackEffect> effects;

  final VoidCallback onAddEffect;
  final ValueChanged<int> onRemoveEffect;
  final void Function(int index, TrackEffectType type) onSetType;
  final void Function(int index, int param, double value) onSetParam;

  /// Sets a hosted-plugin parameter (by stable id, plain value) on the chain
  /// entry at `index`. Distinct from [onSetParam] (built-in, positional).
  final void Function(int index, int paramId, double value) onSetPluginParam;

  /// Opens the native editor window for the plugin chain entry at `index`.
  final ValueChanged<int> onOpenPluginEditor;

  /// Relinks the unavailable plugin chain entry at `index` (D-MISS).
  final ValueChanged<int> onRelinkPlugin;

  /// Moves the chain entry at `oldIndex` to `newIndex` (a post-removal target).
  /// The processing order is the signal order, so a drag re-sequences the FX.
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  State<SignalFxRack> createState() => _SignalFxRackState();
}

class _SignalFxRackState extends State<SignalFxRack> {
  /// The index a card just landed at, played with a settle "pop". [_dropGen]
  /// bumps each drop so the animation restarts for the freshly-dropped card.
  int? _landedAt;
  int _dropGen = 0;

  /// A card is built up to three times by [_DraggableDevice] (in place, as the
  /// lifted feedback, and as the faded gap left behind) — one builder for all.
  Widget _card(int i) {
    final fx = widget.effects[i];
    if (fx is PluginEffect) {
      return _PluginDeviceCard(
        cardKey: Key('${widget.keyPrefix}_device_$i'),
        keyPrefix: '${widget.keyPrefix}_device_$i',
        fx: fx,
        onSetParam: (id, v) => widget.onSetPluginParam(i, id, v),
        onOpenEditor: () => widget.onOpenPluginEditor(i),
        onRelink: () => widget.onRelinkPlugin(i),
        onRemove: () => widget.onRemoveEffect(i),
      );
    }
    if (fx is! BuiltInEffect) return const SizedBox.shrink();
    return _DeviceCard(
      cardKey: Key('${widget.keyPrefix}_device_$i'),
      keyPrefix: '${widget.keyPrefix}_device_$i',
      fx: fx,
      onSetType: (t) => widget.onSetType(i, t),
      onSetParam: (p, v) => widget.onSetParam(i, p, v),
      onRemove: () => widget.onRemoveEffect(i),
    );
  }

  /// A drop onto the gap [insertAt] (an index in the current list). Adjacent
  /// gaps are no-ops; otherwise normalise to the post-removal target and flag
  /// it so the landed card pops into place.
  void _reorderTo(int from, int insertAt) {
    if (insertAt == from || insertAt == from + 1) return;
    final to = insertAt > from ? insertAt - 1 : insertAt;
    setState(() {
      _landedAt = to;
      _dropGen++;
    });
    widget.onReorder(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final keyPrefix = widget.keyPrefix;
    final effects = widget.effects;
    final full = effects.length >= kTrackEffectMax;
    return SizedBox(
      height: 150,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < effects.length; i++) ...[
              // A drop zone sits before every card; a card dragged over it
              // lights up an insertion bar and drops in at that gap.
              _DropSlot(
                slotKey: Key('${keyPrefix}_drop_$i'),
                insertAt: i,
                onDrop: _reorderTo,
              ),
              _DraggableDevice(
                index: i,
                card: _card(i),
                landingKey: i == _landedAt ? ValueKey(_dropGen) : null,
              ),
            ],
            _DropSlot(
              slotKey: Key('${keyPrefix}_drop_${effects.length}'),
              insertAt: effects.length,
              onDrop: _reorderTo,
            ),
            _AddDeviceCard(
              cardKey: Key('${keyPrefix}_addDevice'),
              onAdd: full ? null : widget.onAddEffect,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps a device card so it can be picked up and dropped into a [_DropSlot].
/// The drag has a **horizontal** affinity: a sideways grab lifts the card,
/// while a vertical drag falls through to the knob under the finger.
class _DraggableDevice extends StatelessWidget {
  const _DraggableDevice({
    required this.index,
    required this.card,
    this.landingKey,
  });

  final int index;
  final Widget card;

  /// When set, the in-place card just landed here — wrap it in a settle pop.
  final Key? landingKey;

  @override
  Widget build(BuildContext context) {
    final key = landingKey;
    final inPlace = key == null ? card : _DropLanding(key: key, child: card);
    return Draggable<int>(
      data: index,
      affinity: Axis.horizontal,
      feedback: _LiftedCard(child: card),
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: inPlace,
    );
  }
}

/// The lifted card shown under the pointer while dragging — scaled up a touch
/// and dropped on a soft shadow so it reads as picked up off the rack.
class _LiftedCard extends StatelessWidget {
  const _LiftedCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      // The overlay is unbounded vertically, so pin the lifted card's height.
      child: SizedBox(
        height: 150,
        child: Transform.scale(
          scale: 1.04,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 22,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A one-shot settle "pop" played the moment a dragged card lands in its slot:
/// it arrives slightly enlarged and springs down to rest.
class _DropLanding extends StatelessWidget {
  const _DropLanding({required Key super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.12, end: 1),
      duration: Durations.medium1,
      curve: _dropSettleCurve,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: child,
    );
  }
}

/// The gap between cards, doubling as a [DragTarget]: it widens and shows a
/// glowing insertion bar while a card hovers, and drops it in on release.
class _DropSlot extends StatelessWidget {
  const _DropSlot({
    required this.slotKey,
    required this.insertAt,
    required this.onDrop,
  });

  final Key slotKey;

  /// The index this gap would insert a dropped card at, in the current list.
  final int insertAt;
  final void Function(int from, int insertAt) onDrop;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DragTarget<int>(
      key: slotKey,
      // The gaps flanking a card are no-ops — dropping there changes nothing.
      onWillAcceptWithDetails: (d) =>
          d.data != insertAt && d.data + 1 != insertAt,
      onAcceptWithDetails: (d) => onDrop(d.data, insertAt),
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: Durations.short3,
          width: active ? 30 : 9,
          alignment: Alignment.center,
          child: active
              ? Container(
                  width: 3,
                  height: 118,
                  decoration: BoxDecoration(
                    color: surface.accent,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: signalGlow(surface.accent, blur: 10, spread: 0),
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.cardKey,
    required this.keyPrefix,
    required this.fx,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemove,
  });

  final Key cardKey;
  final String keyPrefix;
  final BuiltInEffect fx;
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemove;

  /// Slot widths so every control lands on an even grid; a two-state mode gets
  /// a wider slot for its switch + algorithm names, with enough margin that the
  /// switch keeps a knob-sized gap (~24px) from its neighbours.
  static const double _knobSlot = 60;
  static const double _modeSlot = 112;

  static double _slotWidth(TrackEffectParam spec) =>
      spec.readout == ParamReadout.octaverMode ? _modeSlot : _knobSlot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final params = fx.type.params;
    final bodyWidth = params.fold<double>(0, (a, p) => a + _slotWidth(p));
    // 20 = 16 body padding + 2 border + 2 slack; the 132 floor keeps the header
    // (type + remove) from cramping on a one- or two-knob effect.
    final cardWidth = bodyWidth + 20 < 132 ? 132.0 : bodyWidth + 20;
    return Container(
      key: cardKey,
      width: cardWidth,
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: kSignalLine2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Device header: type (tap to change) + remove. The whole card is
          // press-and-hold draggable; the header reads as its grab strip.
          MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Container(
              padding: const EdgeInsets.fromLTRB(9, 6, 4, 6),
              decoration: BoxDecoration(
                color: surface.accent.withValues(alpha: 0.10),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
                border: Border(bottom: BorderSide(color: surface.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: PopupMenuButton<TrackEffectType>(
                      key: Key('${keyPrefix}_type'),
                      tooltip: l10n.a11yEffectType,
                      padding: EdgeInsets.zero,
                      onSelected: onSetType,
                      color: kSignalMenu,
                      shape: signalMenuShape(),
                      elevation: 10,
                      menuPadding: const EdgeInsets.symmetric(vertical: 5),
                      position: PopupMenuPosition.under,
                      itemBuilder: (context) => [
                        // `none` is omitted: a device is removed with its ×, so
                        // a "None" type would only make one that does nothing.
                        for (final type in TrackEffectType.values)
                          if (type != TrackEffectType.none)
                            PopupMenuItem<TrackEffectType>(
                              value: type,
                              height: 34,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      l10n.effectTypeLabel(type),
                                      style: signalMono(
                                        color: type == fx.type
                                            ? surface.accent
                                            : surface.textPrimary,
                                        size: 12,
                                        weight: type == fx.type
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                  if (type == fx.type)
                                    Icon(
                                      Icons.check,
                                      size: 14,
                                      color: surface.accent,
                                    ),
                                ],
                              ),
                            ),
                      ],
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              l10n.effectTypeLabel(fx.type),
                              overflow: TextOverflow.ellipsis,
                              style: signalMono(
                                color: surface.textPrimary,
                                tracking: 0.4,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            size: 16,
                            color: surface.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('${keyPrefix}_remove'),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    iconSize: 15,
                    color: surface.textTertiary,
                    tooltip: l10n.removeEffectTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: onRemove,
                  ),
                ],
              ),
            ),
          ),
          // The device's parameters as knobs.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: params.isEmpty
                  ? Center(
                      child: Text(
                        l10n.emDash,
                        style: signalMono(color: surface.textTertiary),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var p = 0; p < params.length; p++)
                          SizedBox(
                            width: _slotWidth(params[p]),
                            child: _ParamControl(
                              keyPrefix: keyPrefix,
                              fx: fx,
                              param: p,
                              onSetParam: onSetParam,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A hosted-plugin device card (sibling to [_DeviceCard]): the plugin's name +
/// bypass + an **Open Editor** button (opens the plugin's native window), with
/// the first [kPluginKnobs] automatable, non-hidden params as in-app knobs. A
/// plugin that exposes no such params shows just the chrome.
class _PluginDeviceCard extends StatelessWidget {
  const _PluginDeviceCard({
    required this.cardKey,
    required this.keyPrefix,
    required this.fx,
    required this.onSetParam,
    required this.onOpenEditor,
    required this.onRelink,
    required this.onRemove,
  });

  final Key cardKey;
  final String keyPrefix;
  final PluginEffect fx;
  final void Function(int paramId, double value) onSetParam;
  final VoidCallback onOpenEditor;
  final VoidCallback onRelink;
  final VoidCallback onRemove;

  static const double _knobSlot = 60;

  /// The plugin's bypass control, if it exposes one — drives the header toggle.
  PluginParamInfo? get _bypassParam =>
      fx.params.where((p) => p.isBypass).firstOrNull;

  /// The params that earn an in-app knob: user-visible (automatable + not
  /// hidden), excluding the bypass control (it has its own header toggle),
  /// capped at [kPluginKnobs].
  List<PluginParamInfo> get _knobParams => fx.params
      .where((p) => p.isUserVisible && !p.isBypass)
      .take(kPluginKnobs)
      .toList();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    // D-MISS: an unresolved plugin renders a placeholder that preserves the
    // entry (ref + state survive) and offers a relink, not its controls.
    if (fx.unavailable) {
      return _PluginPlaceholderCard(
        cardKey: cardKey,
        keyPrefix: keyPrefix,
        title: fx.ref.id.isEmpty ? l10n.signalPluginUnknownName : fx.ref.id,
        onRelink: onRelink,
        onRemove: onRemove,
      );
    }
    final knobs = _knobParams;
    final bypass = _bypassParam;
    final bodyWidth = knobs.length * _knobSlot;
    final cardWidth = bodyWidth + 20 < 150 ? 150.0 : bodyWidth + 20;
    // Prefer the catalog-resolved display name; fall back to the stable id
    // (then a generic label) when it hasn't resolved.
    final name = fx.name.isNotEmpty
        ? fx.name
        : (fx.ref.id.isEmpty ? l10n.signalPluginUnknownName : fx.ref.id);
    return Container(
      key: cardKey,
      width: cardWidth,
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: kSignalLine2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Container(
              padding: const EdgeInsets.fromLTRB(9, 6, 4, 6),
              decoration: BoxDecoration(
                color: surface.accent.withValues(alpha: 0.10),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
                border: Border(bottom: BorderSide(color: surface.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      key: Key('${keyPrefix}_name'),
                      overflow: TextOverflow.ellipsis,
                      style: signalMono(
                        color: surface.textPrimary,
                        tracking: 0.4,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Opens the plugin's own native editor window (D-WIN).
                  IconButton(
                    key: Key('${keyPrefix}_openEditor'),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    iconSize: 14,
                    color: surface.textSecondary,
                    tooltip: l10n.signalPluginOpenEditorTooltip,
                    icon: const Icon(Icons.open_in_new),
                    onPressed: onOpenEditor,
                  ),
                  _BypassToggle(
                    toggleKey: Key('${keyPrefix}_bypass'),
                    bypass: bypass,
                    value: bypass == null
                        ? 0
                        : fx.paramValues[bypass.id] ?? bypass.def,
                    onChanged: (v) => onSetParam(bypass!.id, v),
                    tooltip: l10n.signalPluginBypassTooltip,
                  ),
                  IconButton(
                    key: Key('${keyPrefix}_remove'),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    iconSize: 15,
                    color: surface.textTertiary,
                    tooltip: l10n.removeEffectTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: onRemove,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: knobs.isEmpty
                  ? Center(
                      child: Text(
                        l10n.emDash,
                        style: signalMono(color: surface.textTertiary),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var k = 0; k < knobs.length; k++)
                          SizedBox(
                            width: _knobSlot,
                            child: _PluginParamKnob(
                              knobKey: Key('${keyPrefix}_param_$k'),
                              spec: knobs[k],
                              value:
                                  fx.paramValues[knobs[k].id] ?? knobs[k].def,
                              onChanged: (v) => onSetParam(knobs[k].id, v),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The D-MISS placeholder for an unresolved plugin (uninstalled / moved): keeps
/// the slot visible with its id, a relink action, and remove — the entry's
/// identity + opaque state are preserved in the model, never silently dropped.
class _PluginPlaceholderCard extends StatelessWidget {
  const _PluginPlaceholderCard({
    required this.cardKey,
    required this.keyPrefix,
    required this.title,
    required this.onRelink,
    required this.onRemove,
  });

  final Key cardKey;
  final String keyPrefix;
  final String title;
  final VoidCallback onRelink;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Container(
      key: cardKey,
      width: 150,
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: surface.textTertiary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(9, 6, 4, 6),
            decoration: BoxDecoration(
              color: surface.textTertiary.withValues(alpha: 0.10),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
              border: Border(bottom: BorderSide(color: surface.line)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 13,
                  color: surface.textTertiary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    key: Key('${keyPrefix}_name'),
                    overflow: TextOverflow.ellipsis,
                    style: signalMono(
                      color: surface.textSecondary,
                      tracking: 0.4,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: Key('${keyPrefix}_remove'),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  iconSize: 15,
                  color: surface.textTertiary,
                  tooltip: l10n.removeEffectTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: onRemove,
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    l10n.signalPluginUnavailable,
                    textAlign: TextAlign.center,
                    style: signalMono(color: surface.textTertiary, size: 10),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: Key('${keyPrefix}_relink'),
                    onPressed: onRelink,
                    icon: const Icon(Icons.link, size: 14),
                    label: Text(
                      l10n.signalPluginRelinkTooltip,
                      style: signalMono(color: surface.textSecondary, size: 9),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      side: BorderSide(color: surface.line),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The plugin card's bypass control: an accent-lit toggle when the plugin
/// exposes a bypass param, or a disabled icon when it does not (so the chrome
/// stays consistent across plugins).
class _BypassToggle extends StatelessWidget {
  const _BypassToggle({
    required this.toggleKey,
    required this.bypass,
    required this.value,
    required this.onChanged,
    required this.tooltip,
  });

  final Key toggleKey;
  final PluginParamInfo? bypass;

  /// The bypass param's current plain value (`>= 0.5` = bypassed).
  final double value;
  final ValueChanged<double> onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final bypassed = bypass != null && value >= 0.5;
    return IconButton(
      key: toggleKey,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      iconSize: 15,
      color: bypassed ? surface.accent : surface.textTertiary,
      tooltip: tooltip,
      icon: Icon(bypassed ? Icons.power_settings_new : Icons.power_off),
      // Disabled (null) when there is no bypass param to drive.
      onPressed: bypass == null ? null : () => onChanged(bypassed ? 0 : 1),
    );
  }
}

/// One hosted-plugin parameter as a rotary [SignalKnob]. The plugin reports the
/// value in its own plain `[min, max]` range; the knob works in `0..1`, so we
/// normalize in and de-normalize out, and read out the live plain value.
class _PluginParamKnob extends StatelessWidget {
  const _PluginParamKnob({
    required this.knobKey,
    required this.spec,
    required this.value,
    required this.onChanged,
  });

  final Key knobKey;
  final PluginParamInfo spec;

  /// The current plain value (in `[spec.min, spec.max]`).
  final double value;

  /// Called with the new plain value as the knob turns.
  final ValueChanged<double> onChanged;

  double get _span => spec.max - spec.min;

  double _normalize(double plain) =>
      _span == 0 ? 0.0 : ((plain - spec.min) / _span).clamp(0.0, 1.0);

  double _denormalize(double norm) => spec.min + norm * _span;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SignalKnob(
      knobKey: knobKey,
      value: _normalize(value),
      resetValue: _normalize(spec.def),
      onChanged: (norm) => onChanged(_denormalize(norm)),
      label: spec.name,
      color: surface.accent,
      size: 36,
      readoutBuilder: (norm) {
        final plain = _denormalize(norm);
        final text = spec.stepCount > 0
            ? plain.round().toString()
            : plain.toStringAsFixed(2);
        return spec.unit.isEmpty ? text : '$text ${spec.unit}';
      },
    );
  }
}

/// One parameter control within a device card: a rotary [SignalKnob] for a
/// continuous param, or a two-state [_ModeSwitch] for a mode (a knob reads
/// poorly for a binary algorithm pick).
class _ParamControl extends StatelessWidget {
  const _ParamControl({
    required this.keyPrefix,
    required this.fx,
    required this.param,
    required this.onSetParam,
  });

  final String keyPrefix;
  final BuiltInEffect fx;
  final int param;
  final void Function(int param, double value) onSetParam;

  String _readout(AppLocalizations l10n, TrackEffectParam spec, double v) {
    final c = v.clamp(0.0, 1.0);
    return switch (spec.readout) {
      ParamReadout.none => '${(c * 100).round()}%',
      ParamReadout.pitchShift => l10n.formatLocalizedPitchShift(c),
      ParamReadout.octaverMode => l10n.octaverModeLabel(c),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final spec = fx.type.params[param];
    final defaults = fx.type.defaultParams;
    final value = param < fx.params.length ? fx.params[param] : 0.0;
    if (spec.readout == ParamReadout.octaverMode) {
      return _ModeSwitch(
        switchKey: Key('${keyPrefix}_param_$param'),
        value: value,
        label: l10n.effectParamLabel(spec.label),
        optionLow: l10n.octaverModeLabel(0),
        optionHigh: l10n.octaverModeLabel(1),
        onChanged: (v) => onSetParam(param, v),
      );
    }
    return SignalKnob(
      knobKey: Key('${keyPrefix}_param_$param'),
      value: value,
      resetValue: param < defaults.length ? defaults[param] : null,
      snapTargets: param < defaults.length ? [defaults[param]] : const [],
      onChanged: (v) => onSetParam(param, v),
      label: l10n.effectParamLabel(spec.label),
      color: surface.accent,
      size: 36,
      readoutBuilder: (v) => _readout(l10n, spec, v),
    );
  }
}

/// A two-state parameter rendered as a vertical segmented switch (named
/// algorithm options) rather than a rotary knob — the studio convention for a
/// discrete mode pick. Shares the knob's footprint + caption rhythm so it lines
/// up with neighbouring knobs in a device card.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.value,
    required this.label,
    required this.optionLow,
    required this.optionHigh,
    required this.onChanged,
    this.switchKey,
  });

  /// `0..1`; `< 0.5` selects [optionLow], otherwise [optionHigh].
  final double value;

  /// The mono caption under the switch (e.g. `MODE`).
  final String label;

  /// The name shown for the low (`0`) and high (`1`) states.
  final String optionLow;
  final String optionHigh;

  final ValueChanged<double> onChanged;
  final Key? switchKey;

  /// The switch box's fixed width — narrower than its slot so it sits centred
  /// with the same horizontal breathing room a knob has from its neighbours.
  static const double _switchWidth = 88;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final high = value >= 0.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: switchKey,
          width: _switchWidth,
          height: 36,
          decoration: BoxDecoration(
            color: kSignalInset,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kSignalLine2),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Expanded(
                child: _ModeSegment(
                  text: optionLow,
                  active: !high,
                  color: surface.accent,
                  onTap: () => onChanged(0),
                ),
              ),
              Container(height: 1, color: kSignalLine2),
              Expanded(
                child: _ModeSegment(
                  text: optionHigh,
                  active: high,
                  color: surface.accent,
                  onTap: () => onChanged(1),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label.toUpperCase(),
          style: signalMono(color: surface.textTertiary, size: 9, tracking: 1),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        // A phantom readout slot so the switch column is the same height as a
        // knob's (control + label + readout) and the row centres them as one —
        // keeping MODE level with the neighbouring knob captions.
        const SizedBox(height: 16),
      ],
    );
  }
}

/// One selectable row of a [_ModeSwitch]: lit with the accent when active.
class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    required this.text,
    required this.active,
    required this.color,
    required this.onTap,
  });

  final String text;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        color: active ? color.withValues(alpha: 0.16) : null,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: signalMono(
            color: active ? color : surface.textTertiary,
            size: 8.5,
            tracking: 0.2,
            weight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _AddDeviceCard extends StatelessWidget {
  const _AddDeviceCard({required this.cardKey, required this.onAdd});

  final Key cardKey;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final disabled = onAdd == null;
    final tint = disabled ? surface.textTertiary : surface.textSecondary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: cardKey,
        onTap: onAdd,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 92,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: kSignalLine2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 18, color: tint),
              const SizedBox(height: 6),
              Text(
                l10n.signalAddEffectTooltip,
                textAlign: TextAlign.center,
                style: signalMono(color: tint, size: 9, tracking: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
