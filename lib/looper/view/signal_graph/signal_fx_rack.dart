import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal_graph/fx_param_edit_sheet.dart';
import 'package:segno/looper/view/signal_graph/fx_param_tile.dart';
import 'package:segno/looper/view/signal_graph/signal_fx_chrome.dart';
import 'package:segno/looper/view/signal_graph/signal_knob.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/surface_theme.dart';

/// The settle "pop" a dragged device card plays as it lands — it arrives
/// slightly enlarged and springs down to rest. Deliberately overshoots, which
/// the Material 3 [Easing] set never does, so it stays a named [Curves] value
/// rather than an M3 motion token.
const Curve _dropSettleCurve = Curves.easeOutBack;

/// The widest a hosted-plugin device card grows in-rack before its knob row
/// scrolls internally rather than pushing the rack wider. Every user-visible
/// parameter still gets a knob; this only bounds the card's footprint so a
/// many-param plugin doesn't run off the rack (the native editor, part 6, is
/// still the full surface).
const double kPluginCardMaxBodyWidth = 360;

/// The standard device-card height (one control row) — the rack's floor. A
/// plugin with more controls than fit one row grows the whole strip taller
/// (uniform, so drag-drop stays simple) up to [kSignalRackMaxHeight].
const double kSignalRackMinHeight = 150;

/// The tallest the rack grows for a many-control plugin before that plugin's
/// control grid scrolls vertically inside its card instead.
const double kSignalRackMaxHeight = 348;

/// An **Ableton-style FX rack**: the chain laid out as horizontal **device
/// cards**, each showing its type and its parameters as live knobs — rather
/// than a chip list with one editor at a time. Shared by both docks.
class SignalFxRack extends StatefulWidget {
  /// Creates a [SignalFxRack].
  const SignalFxRack({
    required this.keyPrefix,
    required this.effects,
    required this.onAddEffect,
    required this.onAddPlugin,
    required this.onRemoveEffect,
    required this.onSetType,
    required this.onSetParam,
    required this.onSetPluginParam,
    required this.onOpenPluginEditor,
    required this.onRelinkPlugin,
    required this.onReorder,
    required this.onSetEffectEnabled,
    this.chainEnabled = true,
    this.onFormatPluginValue,
    super.key,
  });

  /// Selector namespace (`signalGraph_input` / `signalGraph_lane`).
  final String keyPrefix;

  /// The chain, in processing order.
  final List<TrackEffect> effects;

  /// Whether the WHOLE chain is engaged (R15). A disabled chain silences every
  /// card regardless of its own flag, so the cards read the same way the
  /// surface's summary chips already do rather than staying lit while the
  /// chain they belong to is off.
  final bool chainEnabled;

  /// Appends a built-in effect of the picked type, as one action — the rack
  /// never composes an append with a retype of an index it had to guess.
  final ValueChanged<TrackEffectType> onAddEffect;

  /// Opens the plugin browser to add a hosted plugin to the chain.
  final VoidCallback onAddPlugin;

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

  /// Powers the chain entry at `index` on/off — the ONE power control per card
  /// (D-POWER, R23), identical for built-ins and hosted plugins. A plugin's own
  /// bypass parameter is part of its sound and never drives this.
  final void Function(int index, {required bool enabled}) onSetEffectEnabled;

  /// Formats plugin chain entry `index`'s parameter `paramId` at the plain
  /// `value` to the plugin's own display string, or null when unavailable —
  /// drives the in-app knob readout in the plugin's real units. Optional.
  final String? Function(int index, int paramId, double value)?
  onFormatPluginValue;

  @override
  State<SignalFxRack> createState() => _SignalFxRackState();
}

class _SignalFxRackState extends State<SignalFxRack> {
  /// The index a card just landed at, played with a settle "pop". [_dropGen]
  /// bumps each drop so the animation restarts for the freshly-dropped card.
  int? _landedAt;
  int _dropGen = 0;

  /// What the user HEARS from slot [i]: its own power flag AND its chain's.
  /// The power control still reflects the slot's own flag, so switching the
  /// chain back on restores exactly the per-slot picture the user left.
  bool _audible(int i) => widget.effects[i].enabled && widget.chainEnabled;

  /// A card is built up to three times by [_DraggableDevice] (in place, as the
  /// lifted feedback, and as the faded gap left behind) — one builder for all.
  Widget _card(int i) {
    final fx = widget.effects[i];
    void togglePower({required bool enabled}) =>
        widget.onSetEffectEnabled(i, enabled: enabled);
    final audible = _audible(i);
    if (fx is PluginEffect) {
      return _PluginDeviceCard(
        cardKey: Key('${widget.keyPrefix}_device_$i'),
        keyPrefix: '${widget.keyPrefix}_device_$i',
        fx: fx,
        audible: audible,
        onSetParam: (id, v) => widget.onSetPluginParam(i, id, v),
        onFormatValue: (paramId, value) =>
            widget.onFormatPluginValue?.call(i, paramId, value),
        onOpenEditor: () => widget.onOpenPluginEditor(i),
        onRelink: () => widget.onRelinkPlugin(i),
        onRemove: () => widget.onRemoveEffect(i),
        onSetEnabled: togglePower,
      );
    }
    if (fx is! BuiltInEffect) return const SizedBox.shrink();
    return _DeviceCard(
      cardKey: Key('${widget.keyPrefix}_device_$i'),
      keyPrefix: '${widget.keyPrefix}_device_$i',
      fx: fx,
      audible: audible,
      onSetType: (t) => widget.onSetType(i, t),
      onSetParam: (p, v) => widget.onSetParam(i, p, v),
      onRemove: () => widget.onRemoveEffect(i),
      onSetEnabled: togglePower,
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
    // All devices in a chain share one height (so the strip + drag-drop stay
    // uniform), grown to fit the tallest plugin's multi-row control grid.
    var rackHeight = kSignalRackMinHeight;
    for (final fx in effects) {
      if (fx is PluginEffect) {
        rackHeight = math.max(rackHeight, _PluginDeviceCard.heightFor(fx));
      }
    }
    return SizedBox(
      height: rackHeight,
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
                height: rackHeight - 32,
                onDrop: _reorderTo,
              ),
              _DraggableDevice(
                index: i,
                height: rackHeight,
                card: _card(i),
                dimmed: !_audible(i),
                landingKey: i == _landedAt ? ValueKey(_dropGen) : null,
              ),
            ],
            _DropSlot(
              slotKey: Key('${keyPrefix}_drop_${effects.length}'),
              insertAt: effects.length,
              height: rackHeight - 32,
              onDrop: _reorderTo,
            ),
            _AddDeviceCard(
              cardKey: Key('${keyPrefix}_addDevice'),
              onAddEffectType: full ? null : widget.onAddEffect,
              onAddPlugin: full ? null : widget.onAddPlugin,
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
    required this.height,
    required this.card,
    required this.dimmed,
    this.landingKey,
  });

  final int index;

  /// Whether [card] already renders dimmed (silenced), so the drag gap must not
  /// dim it a second time.
  final bool dimmed;

  /// The shared device-card height for this chain (the rack's resolved height).
  final double height;
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
      feedback: _LiftedCard(height: height, child: card),
      // A card whose body already carries the disabled dim is left as-is: a
      // second opacity layer here would multiply with it and sink its controls
      // far below the disabled token (which the high-contrast variant raises
      // precisely to stay legible).
      childWhenDragging: dimmed ? card : Opacity(opacity: 0.3, child: card),
      child: inPlace,
    );
  }
}

/// The lifted card shown under the pointer while dragging — scaled up a touch
/// and dropped on a soft shadow so it reads as picked up off the rack.
class _LiftedCard extends StatelessWidget {
  const _LiftedCard({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      // The overlay is unbounded vertically, so pin the lifted card's height.
      child: SizedBox(
        height: height,
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
    required this.height,
    required this.onDrop,
  });

  final Key slotKey;

  /// The index this gap would insert a dropped card at, in the current list.
  final int insertAt;

  /// The height of the insertion bar — matches the chain's card height.
  final double height;
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
                  height: height,
                  decoration: BoxDecoration(
                    color: surface.accent,
                    borderRadius: BorderRadius.circular(2),
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
    required this.audible,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemove,
    required this.onSetEnabled,
  });

  final Key cardKey;
  final String keyPrefix;
  final BuiltInEffect fx;

  /// Whether this slot is heard — its own power flag AND its chain's.
  final bool audible;
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemove;

  /// Powers this device on/off (D-POWER, R23).
  final void Function({required bool enabled}) onSetEnabled;

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
    // 20 = 16 body padding + 2 border + 2 slack; the 158 floor keeps the header
    // (type + power + remove) from cramping on a one- or two-knob effect —
    // wide enough that the type name is not elided by its own controls.
    final cardWidth = bodyWidth + 20 < 158 ? 158.0 : bodyWidth + 20;
    return Container(
      key: cardKey,
      width: cardWidth,
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: surface.line),
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
                      color: surface.cardHigh,
                      shape: signalMenuShape(surface),
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
                  _CardPowerToggle(
                    keyPrefix: keyPrefix,
                    enabled: fx.enabled,
                    onChanged: onSetEnabled,
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
          // The device's parameters as knobs — dimmed while powered off, with
          // the header above left at full strength (R26).
          Expanded(
            // Inert while silenced, not merely dimmed: an opacity wrapper still
            // hit-tests, so without this the knobs of a card the UI is showing
            // as off would keep writing (and persisting) parameter changes.
            child: IgnorePointer(
              ignoring: !audible,
              child: FxDisabledDim(
                enabled: audible,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
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
            ),
          ),
        ],
      ),
    );
  }
}

/// A hosted-plugin device card (sibling to [_DeviceCard]): the plugin's name +
/// the universal power control + an **Open Editor** button (opens the plugin's
/// native window), with every automatable, non-hidden param as an in-app knob.
/// The plugin's OWN bypass parameter is deliberately absent from the header
/// (D-POWER, R23): it is part of the plugin's sound, it is still reachable in
/// the native editor, and it never drives the host's enable. The knob strip
/// scrolls horizontally once it would push the card past
/// [kPluginCardMaxBodyWidth], so a many-param plugin shows all its controls
/// without running off the rack. A plugin that exposes no such params shows
/// just the chrome.
class _PluginDeviceCard extends StatelessWidget {
  const _PluginDeviceCard({
    required this.cardKey,
    required this.keyPrefix,
    required this.fx,
    required this.audible,
    required this.onSetParam,
    required this.onOpenEditor,
    required this.onRelink,
    required this.onRemove,
    required this.onSetEnabled,
    this.onFormatValue,
  });

  final Key cardKey;
  final String keyPrefix;
  final PluginEffect fx;

  /// Whether this slot is heard — its own power flag AND its chain's.
  final bool audible;
  final void Function(int paramId, double value) onSetParam;

  /// Formats a parameter's plain value to the plugin's own display string (e.g.
  /// `-6.0 dB`), or null when no live readout is available — drives the knob
  /// readout in the plugin's real units. Null disables the live readout.
  final String? Function(int paramId, double value)? onFormatValue;

  final VoidCallback onOpenEditor;
  final VoidCallback onRelink;
  final VoidCallback onRemove;

  /// Powers this plugin slot on/off (D-POWER, R23) — the host-side enable,
  /// never the plugin's own bypass parameter.
  final void Function({required bool enabled}) onSetEnabled;

  // DS / 06: every parameter kind wears the same 78x59 skeleton, so the strip
  // is one grid rather than a row of unlike controls sized by kind.
  static const double _slot =
      FxParamTileMetrics.width + FxParamTileMetrics.gutter;
  static const double _cellHeight =
      FxParamTileMetrics.height + FxParamTileMetrics.gutter;
  static const double _headerHeight = 33;
  static const double _bodyVPad = 16; // 8 top + 8 bottom

  /// The params that earn an in-app control: every user-visible (automatable
  /// and not hidden) param, except the plugin's own bypass — that one belongs
  /// to the plugin's sound and stays in its native editor, so the card's single
  /// power control is unambiguously the host enable (D-POWER, R23). Each
  /// renders per [_PluginParamControl]'s mapping.
  ///
  /// **Open conflict, deliberately unresolved here.** `DS / 06` routes
  /// `isBypass` to an `FxBypassPill` in the chain chrome instead of dropping
  /// it. That is a reversal of D-POWER/R23, not a reskin: it adds a second
  /// bypass-shaped control beside the host enable, which is the exact ambiguity
  /// R23 exists to prevent. #505 filed it as "a real bug — the param is
  /// silently dropped", but the drop is documented right here and in the class
  /// doc, so that premise does not hold. Left as-is pending a human call;
  /// promoting it is a self-contained change to this method plus a pill.
  static List<PluginParamInfo> _visibleControls(PluginEffect fx) =>
      fx.params.where((p) => p.isUserVisible && !p.isBypass).toList();

  List<PluginParamInfo> get _controlParams => _visibleControls(fx);

  /// The in-strip width a parameter occupies. Uniform by design (DS / 06): an
  /// enum's longer label ellipsizes rather than widening its cell, so columns
  /// stay aligned down the grid.
  static double _slotWidth(PluginParamInfo param) => _slot;

  /// How many rows [widths] wrap into within a [maxWidth] body (greedy, the way
  /// [Wrap] packs them) — drives the card's height so every control is visible.
  static int _rowsFor(List<double> widths, double maxWidth) {
    var rows = 1;
    var x = 0.0;
    for (final w in widths) {
      if (x > 0 && x + w > maxWidth + 0.5) {
        rows++;
        x = 0;
      }
      x += w;
    }
    return rows;
  }

  /// The shared device-card height this plugin needs to lay its controls out in
  /// a multi-row grid — the rack grows every card to the tallest of these. An
  /// unavailable / control-less plugin keeps the standard one-row height; a very
  /// dense plugin is clamped to [kSignalRackMaxHeight] (its grid then scrolls).
  static double heightFor(PluginEffect fx) {
    final controls = _visibleControls(fx);
    if (fx.unavailable || fx.loading || controls.isEmpty) {
      return kSignalRackMinHeight;
    }
    final rows = _rowsFor(
      [for (final p in controls) _slotWidth(p)],
      kPluginCardMaxBodyWidth,
    );
    final needed = _headerHeight + _bodyVPad + rows * _cellHeight;
    return needed.clamp(kSignalRackMinHeight, kSignalRackMaxHeight);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    // F5: a plugin still resolving through a cold-boot scan renders a distinct
    // "loading…" placeholder (no relink — it is expected to bind on its own),
    // so a still-scanning entry never reads as a genuine failure.
    // D-MISS: an unresolved plugin renders a placeholder that preserves the
    // entry (ref + state survive) and offers a relink, not its controls.
    if (fx.loading || fx.unavailable) {
      return _PluginPlaceholderCard(
        cardKey: cardKey,
        keyPrefix: keyPrefix,
        // Prefer the persisted display name so a missing plugin reads as its
        // name, not a cryptic id; fall back to the id, then a generic label.
        title: fx.name.isNotEmpty
            ? fx.name
            : (fx.ref.id.isEmpty ? l10n.signalPluginUnknownName : fx.ref.id),
        loading: fx.loading,
        unsupported: fx.unsupported,
        enabled: fx.enabled,
        onRelink: onRelink,
        onRemove: onRemove,
        onSetEnabled: onSetEnabled,
      );
    }
    final controls = _controlParams;
    // The full control strip, clamped so a many-param plugin scrolls inside the
    // card instead of stretching the rack. Knobs turn on a vertical drag, so a
    // horizontal scroll of the strip never fights the knob gesture.
    final fullStripWidth = controls.fold<double>(
      0,
      (w, p) => w + _slotWidth(p),
    );
    final bodyWidth = fullStripWidth > kPluginCardMaxBodyWidth
        ? kPluginCardMaxBodyWidth
        : fullStripWidth;
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
        border: Border.all(color: surface.line),
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
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // D-MISS: the installed version differs from the saved one;
                  // the plugin still loaded, but flag the drift.
                  if (fx.versionChanged)
                    Tooltip(
                      key: Key('${keyPrefix}_versionChanged'),
                      message: l10n.signalPluginVersionChanged,
                      child: Icon(
                        Icons.info_outline,
                        size: 13,
                        color: surface.textTertiary,
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
                  _CardPowerToggle(
                    keyPrefix: keyPrefix,
                    enabled: fx.enabled,
                    onChanged: onSetEnabled,
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
            // Inert while silenced — see the built-in card for why dimming
            // alone would still let the knobs write.
            child: IgnorePointer(
              ignoring: !audible,
              child: FxDisabledDim(
                enabled: audible,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: controls.isEmpty
                      ? Center(
                          child: Text(
                            l10n.emDash,
                            style: signalMono(color: surface.textTertiary),
                          ),
                        )
                      // Every control is shown: they wrap into rows and the
                      // rack grew to fit. A very dense plugin scrolls
                      // vertically here (the native editor is the full
                      // control surface).
                      : SingleChildScrollView(
                          key: Key('${keyPrefix}_params'),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            runAlignment: WrapAlignment.center,
                            children: [
                              for (var k = 0; k < controls.length; k++)
                                SizedBox(
                                  width: _slotWidth(controls[k]),
                                  height: _cellHeight,
                                  child: _PluginParamControl(
                                    controlKey: Key('${keyPrefix}_param_$k'),
                                    spec: controls[k],
                                    value:
                                        fx.paramValues[controls[k].id] ??
                                        controls[k].def,
                                    onChanged: (v) =>
                                        onSetParam(controls[k].id, v),
                                    source: name,
                                    onFormatValue: onFormatValue,
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
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
///
/// It carries the same power control as a resolved card (D-POWER, R23) but is
/// deliberately NOT dimmed when powered off: the warning state is what the user
/// must act on, so it stays visually dominant over the disabled dim (R26).
class _PluginPlaceholderCard extends StatelessWidget {
  const _PluginPlaceholderCard({
    required this.cardKey,
    required this.keyPrefix,
    required this.title,
    required this.unsupported,
    required this.enabled,
    required this.onRelink,
    required this.onRemove,
    required this.onSetEnabled,
    this.loading = false,
  });

  final Key cardKey;
  final String keyPrefix;
  final String title;

  /// Whether the plugin is still resolving through a scan (F5): the card shows
  /// a spinner + "loading…" and NO relink — it is expected to bind on its own.
  final bool loading;

  /// Whether the plugin is installed but rejected (unsupported topology, D-BUS)
  /// rather than simply missing — selects the explanatory message.
  final bool unsupported;

  /// Whether the slot is powered on (D-POWER, R23).
  final bool enabled;
  final VoidCallback onRelink;
  final VoidCallback onRemove;

  /// Powers this slot on/off.
  final void Function({required bool enabled}) onSetEnabled;

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
                if (loading)
                  SizedBox(
                    key: Key('${keyPrefix}_spinner'),
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: surface.textTertiary,
                    ),
                  )
                else
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
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                _CardPowerToggle(
                  keyPrefix: keyPrefix,
                  enabled: enabled,
                  onChanged: onSetEnabled,
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
                    key: Key('${keyPrefix}_reason'),
                    fxPluginPlaceholderReason(
                      l10n,
                      loading: loading,
                      unsupported: unsupported,
                    ),
                    textAlign: TextAlign.center,
                    style: signalLabel(color: surface.textTertiary, size: 10),
                  ),
                  // A loading entry offers no relink — it is expected to bind
                  // once the scan lands (F5).
                  if (!loading) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: Key('${keyPrefix}_relink'),
                      onPressed: onRelink,
                      icon: const Icon(Icons.link, size: 14),
                      label: Text(
                        l10n.signalPluginRelinkTooltip,
                        style: signalMono(
                          color: surface.textSecondary,
                          size: 9,
                        ),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A device card's power control — the shared [FxPowerToggle] with the card's
/// key namespace and the per-effect wording.
class _CardPowerToggle extends StatelessWidget {
  const _CardPowerToggle({
    required this.keyPrefix,
    required this.enabled,
    required this.onChanged,
  });

  final String keyPrefix;
  final bool enabled;
  final void Function({required bool enabled}) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FxPowerToggle(
      toggleKey: Key('${keyPrefix}_power'),
      enabled: enabled,
      onChanged: onChanged,
      semanticLabel: enabled ? l10n.a11yFxEffectOn : l10n.a11yFxEffectOff,
      tooltip: enabled
          ? l10n.fxEffectPowerOffTooltip
          : l10n.fxEffectPowerOnTooltip,
    );
  }
}

/// One hosted-plugin parameter, rendered as the control its kind calls for.
///
/// The mapping is `DS / 06 FX parameter — spec`, read top to bottom with the
/// first match winning:
///
/// | condition                  | control                       |
/// |----------------------------|-------------------------------|
/// | `isReadOnly`               | tile, not tappable (meters)   |
/// | `stepCount == 1`           | [FxParamSwitchCell]           |
/// | `2 <= stepCount <= 24`     | [FxParamEnumCell]             |
/// | `stepCount > 24`           | tile; the sheet snaps to steps|
/// | `stepCount == 0`           | tile; the sheet is continuous |
///
/// `!isAutomatable || isHidden` and `isBypass` never reach here — they are
/// resolved before the grid is built (see `_visibleControls`).
///
/// Rotaries are gone. A knob is poor tactile UX on glass: no grip, imprecise
/// drag, and a finger over the readout — and at `size: 36` it gave ~36px of
/// travel for a full parameter range. The tile is an overview that opens an
/// editor with the panel's full width to drag in.
class _PluginParamControl extends StatelessWidget {
  const _PluginParamControl({
    required this.controlKey,
    required this.spec,
    required this.value,
    required this.onChanged,
    required this.source,
    this.onFormatValue,
  });

  final Key controlKey;
  final PluginParamInfo spec;

  /// The current plain value (in `[spec.min, spec.max]`).
  final double value;
  final ValueChanged<double> onChanged;

  /// Breadcrumb for the editor sheet's header.
  final String source;

  /// The plugin's own readout for a plain value, when it offers one. Switch and
  /// enum cells read their labels from [PluginParamInfo.valueTexts] instead,
  /// baked in at load time.
  final String? Function(int paramId, double value)? onFormatValue;

  @override
  Widget build(BuildContext context) {
    // Read-only first: a meter reports a value but takes none, whatever its
    // step count says.
    if (spec.isReadOnly) {
      return FxParamTile(
        key: controlKey,
        spec: spec,
        value: value,
        valueText: onFormatValue?.call(spec.id, value),
        onTap: null,
      );
    }
    if (spec.isToggle) {
      return FxParamSwitchCell(
        key: controlKey,
        spec: spec,
        value: value,
        onChanged: onChanged,
      );
    }
    // Only a *small* enumeration earns a menu; past 24 steps a menu stops being
    // readable, so it falls through to a tile whose sheet snaps to the steps.
    if (spec.isEnum && spec.stepCount <= _maxMenuSteps) {
      return FxParamEnumCell(
        key: controlKey,
        spec: spec,
        value: value,
        onChanged: onChanged,
      );
    }
    return FxParamTile(
      key: controlKey,
      spec: spec,
      value: value,
      valueText: onFormatValue?.call(spec.id, value),
      onTap: () => unawaited(
        FxParamEditSheet.show(
          context,
          spec: spec,
          value: value,
          source: source,
          onChanged: onChanged,
          formatValue: (v) => onFormatValue?.call(spec.id, v),
        ),
      ),
    );
  }
}

/// The largest step count that still reads as a menu rather than a list
/// (DS / 06). Above it a parameter takes a tile and snaps in the sheet.
const _maxMenuSteps = 24;

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
            color: surface.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: surface.line),
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
              Container(height: 1, color: surface.line),
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
          style: signalMono(color: surface.textTertiary, size: 9),
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
            weight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// The trailing add card: two stacked buttons — add a built-in effect, or
/// browse for a hosted plugin — shown directly (no menu). Disabled (both null)
/// when the chain is at [kTrackEffectMax].
class _AddDeviceCard extends StatelessWidget {
  const _AddDeviceCard({
    required this.cardKey,
    required this.onAddEffectType,
    required this.onAddPlugin,
  });

  final Key cardKey;

  /// Adds a built-in device of the chosen type (the Ableton-style pick), or
  /// null when the chain is full.
  final ValueChanged<TrackEffectType>? onAddEffectType;
  final VoidCallback? onAddPlugin;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Container(
      key: cardKey,
      width: 104,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: surface.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: _AddDeviceMenu(
              menuKey: const Key('signalGraph_addEffect'),
              onAddType: onAddEffectType,
            ),
          ),
          Container(height: 1, color: surface.line),
          Expanded(
            child: _AddDeviceButton(
              buttonKey: const Key('signalGraph_addPlugin'),
              icon: Icons.extension_outlined,
              label: l10n.signalAddPlugin,
              onTap: onAddPlugin,
            ),
          ),
        ],
      ),
    );
  }
}

/// The **device browser** for built-in effects — an Ableton-style picker: tap
/// to choose the device type to add, rather than dropping a default you then
/// retype. Disabled (greyed) when the chain is at capacity.
class _AddDeviceMenu extends StatelessWidget {
  const _AddDeviceMenu({required this.menuKey, required this.onAddType});

  final Key menuKey;
  final ValueChanged<TrackEffectType>? onAddType;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final tint = onAddType == null
        ? surface.textTertiary
        : surface.textSecondary;
    return PopupMenuButton<TrackEffectType>(
      key: menuKey,
      enabled: onAddType != null,
      tooltip: l10n.signalAddEffect,
      color: surface.cardHigh,
      shape: signalMenuShape(surface),
      elevation: 10,
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      position: PopupMenuPosition.under,
      onSelected: (type) => onAddType?.call(type),
      itemBuilder: (context) => [
        // `none` is omitted — a chain never holds a do-nothing device.
        for (final type in TrackEffectType.values)
          if (type != TrackEffectType.none)
            PopupMenuItem<TrackEffectType>(
              value: type,
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                l10n.effectTypeLabel(type),
                style: signalMono(color: surface.textPrimary, size: 12),
              ),
            ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.graphic_eq, size: 16, color: tint),
            const SizedBox(height: 5),
            Text(
              l10n.signalAddEffect,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: signalMono(color: tint, size: 9),
            ),
          ],
        ),
      ),
    );
  }
}

/// One half of the [_AddDeviceCard]: an icon + label tap target, greyed and
/// inert when its [onTap] is null (the chain is full).
class _AddDeviceButton extends StatelessWidget {
  const _AddDeviceButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = onTap == null ? surface.textTertiary : surface.textSecondary;
    return InkWell(
      key: buttonKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: tint),
            const SizedBox(height: 5),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: signalMono(color: tint, size: 9),
            ),
          ],
        ),
      ),
    );
  }
}
