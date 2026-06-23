part of 'signal_list_view.dart';

// --- Rows ----------------------------------------------------------------

class _InputRow extends StatelessWidget {
  const _InputRow({
    required this.row,
    required this.outputCount,
    required this.selected,
    required this.onTap,
    required this.onToggleRoute,
    required this.onToggleGate,
  });

  final InputRow row;
  final int outputCount;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<int> onToggleRoute;
  final VoidCallback onToggleGate;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final m = row.monitor;
    final on = m.enabled && !row.excluded;
    final hue = on ? surface.accent : surface.textTertiary;
    if (row.excluded) {
      return _RowCard(
        rowKey: Key('signalIn_${row.input}'),
        child: Row(
          children: [
            Text(
              l10n.inputChannelLabel(row.input + 1).toUpperCase(),
              style: signalMono(
                color: surface.textTertiary,
                size: 12,
                weight: FontWeight.w600,
              ).copyWith(decoration: TextDecoration.lineThrough),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.a11yPortUnused,
              style: signalMono(color: surface.textTertiary, size: 10),
            ),
          ],
        ),
      );
    }
    return _RowCard(
      rowKey: Key('signalIn_${row.input}'),
      selected: selected,
      onTap: onTap,
      semanticLabel:
          '${l10n.inputMonitorLabel(row.input + 1)}, '
          '${on ? l10n.signalInputLive : l10n.signalInputOff}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.inputChannelLabel(row.input + 1).toUpperCase(),
                style: signalMono(
                  color: surface.textPrimary,
                  size: 12,
                  tracking: 1,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: on ? l10n.signalInputLive : l10n.signalInputOff,
                child: InkWell(
                  key: Key('signalInGate_${row.input}'),
                  onTap: onToggleGate,
                  borderRadius: BorderRadius.circular(20),
                  child: SignalGatePill(
                    label: on ? l10n.signalInputLive : l10n.signalInputOff,
                    on: on,
                    color: surface.accent,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                m.muted
                    ? l10n.trackStateMuted
                    : '${(m.volume.clamp(0.0, 1.0) * 100).round()}%',
                style: signalMono(color: surface.textSecondary, size: 9.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5,
              child: LinearProgressIndicator(
                value: (on && !m.muted) ? m.volume.clamp(0.0, 1.0) : 0,
                backgroundColor: const Color(0xFF0E0E12),
                valueColor: AlwaysStoppedAnimation(hue),
              ),
            ),
          ),
          if (m.effects.isNotEmpty) ...[
            const SizedBox(height: 8),
            _FieldRow(
              label: l10n.signalFieldFx,
              child: _RowFxChips(effects: m.effects),
            ),
          ],
          const SizedBox(height: 8),
          _FieldRow(
            label: l10n.signalFieldOut,
            child: SignalRoutingChips(
              keyPrefix: 'signalIn_${row.input}',
              routes: row.routes,
              outputCount: outputCount,
              onToggle: onToggleRoute,
            ),
          ),
        ],
      ),
    );
  }
}

class _TakeRow extends StatelessWidget {
  const _TakeRow({
    required this.take,
    required this.trackLabel,
    required this.asTrack,
    required this.inputCount,
    required this.outputCount,
    required this.selected,
    required this.onTap,
    required this.onToggleRoute,
    required this.onReassignInput,
  });

  final TakeRow take;
  final String trackLabel;
  final bool asTrack;
  final int inputCount;
  final int outputCount;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<int> onToggleRoute;
  final ValueChanged<int> onReassignInput;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final lane = take.lane;
    final label = asTrack
        ? trackLabel
        : l10n.laneNumberLabel(take.laneIndex + 1);
    return _RowCard(
      rowKey: Key('signalTake_${take.track}_${take.laneIndex}'),
      selected: selected,
      onTap: onTap,
      semanticLabel: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: signalMono(
                  color: surface.textPrimary,
                  size: 12.5,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              _CaptureBadge(
                badgeKey: Key(
                  'signalCapture_${take.track}_${take.laneIndex}',
                ),
                inputChannel: lane.inputChannel,
                inputCount: inputCount,
                onReassign: onReassignInput,
              ),
              const Spacer(),
              Text(
                lane.muted
                    ? l10n.trackStateMuted
                    : '${(lane.volume.clamp(0.0, 1.0) * 100).round()}%',
                style: signalMono(color: surface.textSecondary, size: 9.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _TakeFxLine(effects: lane.effects),
          const SizedBox(height: 8),
          _FieldRow(
            label: l10n.signalFieldOut,
            child: SignalRoutingChips(
              keyPrefix: 'signalTake_${take.track}_${take.laneIndex}',
              routes: take.routes,
              outputCount: outputCount,
              onToggle: onToggleRoute,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({
    required this.row,
    required this.inputs,
    required this.tracks,
    required this.trackNames,
    required this.selected,
    required this.onTap,
    required this.onToggleGate,
  });

  final OutputRow row;

  /// The input + track channels routed into this output, in order.
  final List<int> inputs;
  final List<int> tracks;

  /// Per-track display names (custom or `Track N`), for the track chips.
  final List<String> trackNames;

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleGate;

  String _trackLabel(AppLocalizations l10n, int track) =>
      track < trackNames.length
      ? l10n.displayTrackName(trackNames[track], track)
      : l10n.trackNumberLabel(track + 1);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final hue = outputColor(surface, row.output);
    final nothingRouted = inputs.isEmpty && tracks.isEmpty;
    return _RowCard(
      rowKey: Key('signalOut_${row.output}'),
      rail: row.enabled ? hue : surface.line,
      selected: selected,
      onTap: onTap,
      semanticLabel: row.enabled
          ? l10n.a11yOutputEnabledDisable(row.output + 1)
          : l10n.a11yOutputDisabledEnable(row.output + 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: row.enabled ? hue : surface.textTertiary,
                  boxShadow: row.enabled
                      ? signalGlow(hue, blur: 8, spread: 0)
                      : null,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                l10n.outputChannelLabel(row.output + 1),
                style:
                    signalMono(
                      color: row.enabled
                          ? surface.textPrimary
                          : surface.textTertiary,
                      size: 12.5,
                      weight: FontWeight.w600,
                    ).copyWith(
                      decoration: row.enabled
                          ? null
                          : TextDecoration.lineThrough,
                    ),
              ),
              const Spacer(),
              _GateToggle(
                gateKey: Key('signalGraph_out_${row.output}'),
                on: row.enabled,
                onToggle: onToggleGate,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (nothingRouted)
            Text(
              l10n.signalNothingRouted,
              style: signalMono(color: surface.textTertiary, size: 9.5),
            )
          else ...[
            if (inputs.isNotEmpty)
              _FieldRow(
                label: l10n.signalFieldInputs,
                child: _FeederChips(
                  color: surface.accent,
                  labels: [
                    for (final i in inputs) l10n.inputChannelLabel(i + 1),
                  ],
                ),
              ),
            if (inputs.isNotEmpty && tracks.isNotEmpty)
              const SizedBox(height: 6),
            if (tracks.isNotEmpty)
              _FieldRow(
                label: l10n.signalFieldTracks,
                child: _FeederChips(
                  colors: [for (final t in tracks) surface.laneColor(t)],
                  labels: [for (final t in tracks) _trackLabel(l10n, t)],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// A read-only wrap of source chips on an output card — one per input or track
/// routed in, each tinted with that source's traceable hue. A single [color]
/// tints them all (inputs share the accent); [colors] gives a per-chip hue
/// (each track wears its own lane colour).
class _FeederChips extends StatelessWidget {
  const _FeederChips({required this.labels, this.color, this.colors})
    : assert(
        color != null || colors != null,
        'provide a shared color or per-chip colors',
      );

  final List<String> labels;
  final Color? color;
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < labels.length; i++)
          _FeederChip(label: labels[i], color: colors?[i] ?? color!),
      ],
    );
  }
}

class _FeederChip extends StatelessWidget {
  const _FeederChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: signalMono(
          color: Color.alphaBlend(Colors.white.withValues(alpha: 0.14), color),
          size: 10,
        ),
      ),
    );
  }
}

// --- Small row parts -----------------------------------------------------

class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.child,
    this.rail,
    this.rowKey,
    this.onTap,
    this.semanticLabel,
    this.selected = false,
  });

  final Widget child;

  /// The coloured left rail, or null for no rail (input + track cards).
  final Color? rail;
  final Key? rowKey;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// The tapped card — gets the accent border + glow (mockup `.trace-self`).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final railColor = rail;
    final card = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: selected ? surface.accent : surface.line,
          width: selected ? 1.5 : 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: surface.accent.withValues(alpha: 0.45),
                  blurRadius: 26,
                  spreadRadius: -8,
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(railColor == null ? 13 : 14, 11, 12, 11),
        child: child,
      ),
    );
    // Draw the rail on TOP of the card, but clipped to the card's rounded-rect
    // so it follows the corners and the selection border can't paint over it.
    // The clip wraps only the rail (not the card), so the selection glow is
    // preserved. Omitted entirely when null (input + track cards).
    final content = railColor == null
        ? card
        : Stack(
            children: [
              card,
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Row(
                      children: [
                        Container(
                          width: 3,
                          color: railColor.withValues(alpha: 0.9),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
    final framed = Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: content,
    );
    if (onTap == null) return KeyedSubtree(key: rowKey, child: framed);
    return FocusableTapTarget(
      key: rowKey,
      onTap: onTap,
      borderRadius: 11,
      focusColor: surface.accent,
      semanticLabel: semanticLabel,
      child: framed,
    );
  }
}

/// A labelled field on a row — the small mono caption (`FX` / `OUT`) then its
/// content, inline with a 6px gap (mockup `.meta` + `.lbl`).
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A fixed gutter so the FX / OUT rows' content lines up in a column.
        SizedBox(
          width: 26,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              label,
              style: signalMono(
                color: surface.textTertiary,
                size: 9,
                tracking: 1.4,
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Read-only FX chips for a row (the live input's chain) — bordered mono pills,
/// matching the mockup. Editing happens in the dock.
class _RowFxChips extends StatelessWidget {
  const _RowFxChips({required this.effects});

  final List<TrackEffect> effects;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        // Built-in chips only — plugin entries get their own chip in part 5.
        for (final e in effects.whereType<BuiltInEffect>())
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: kSignalLine2),
            ),
            child: Text(
              l10n.effectTypeLabel(e.type),
              style: signalMono(color: surface.textSecondary, size: 10),
            ),
          ),
      ],
    );
  }
}

/// A take's FX line: the **`✦ snapshot`** badge naming its captured chain
/// (mockup `.snap`), or a dashed **`clean take`** chip when it recorded dry.
class _TakeFxLine extends StatelessWidget {
  const _TakeFxLine({required this.effects});

  final List<TrackEffect> effects;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (effects.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: kSignalLine2),
        ),
        child: Text(
          l10n.signalCleanTake,
          style: signalMono(color: surface.textTertiary, size: 10),
        ),
      );
    }
    final names = effects
        .whereType<BuiltInEffect>()
        .map((e) => l10n.effectTypeLabel(e.type))
        .join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: kSignalSnapshotBg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kSignalSnapshotLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome, size: 11, color: kSignalSnapshotInk),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              names,
              overflow: TextOverflow.ellipsis,
              style: signalMono(color: kSignalSnapshotInk, size: 9.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// The capture badge on a take: `rec In N` (or "clean"), tappable to re-assign
/// the recorded input via a popup picker (D7).
class _CaptureBadge extends StatelessWidget {
  const _CaptureBadge({
    required this.badgeKey,
    required this.inputChannel,
    required this.inputCount,
    required this.onReassign,
  });

  final Key badgeKey;
  final int inputChannel;
  final int inputCount;
  final ValueChanged<int> onReassign;

  /// A capture-picker row: tight + mono, the active input checked in accent.
  PopupMenuItem<int> _captureItem({
    required int value,
    required String label,
    required bool selected,
    required Color color,
    required SurfaceTheme surface,
  }) => PopupMenuItem<int>(
    value: value,
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: signalMono(
              color: selected ? surface.accent : color,
              size: 12,
              weight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        if (selected) Icon(Icons.check, size: 14, color: surface.accent),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final recorded = inputChannel >= 0;
    return PopupMenuButton<int>(
      key: badgeKey,
      tooltip: l10n.signalReassignInput,
      onSelected: onReassign,
      color: kSignalMenu,
      shape: signalMenuShape(),
      elevation: 10,
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        _captureItem(
          value: -1,
          label: l10n.signalInputNone,
          selected: !recorded,
          color: surface.textSecondary,
          surface: surface,
        ),
        for (var i = 0; i < inputCount; i++)
          _captureItem(
            value: i,
            label: l10n.inputChannelLabel(i + 1),
            selected: inputChannel == i,
            color: surface.textPrimary,
            surface: surface,
          ),
      ],
      // mockup `.snap` recessed variant: inset bg, line2 border, t2 text.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: kSignalInset,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: kSignalLine2),
        ),
        child: Text(
          recorded
              ? l10n.signalRecInput(inputChannel + 1)
              : l10n.signalCleanTake,
          style: signalMono(color: surface.textSecondary, size: 9.5),
        ),
      ),
    );
  }
}

class _GateToggle extends StatelessWidget {
  const _GateToggle({
    required this.gateKey,
    required this.on,
    required this.onToggle,
  });

  final Key gateKey;
  final bool on;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: gateKey,
        onTap: onToggle,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: on ? kSignalSnapshotBg : kSignalInset,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: on ? kSignalSnapshotLine : kSignalLine2,
            ),
          ),
          child: Text(
            on ? 'ON' : 'OFF',
            style: signalMono(
              color: on ? kSignalSnapshotInk : surface.textSecondary,
              size: 9,
              tracking: 1,
            ),
          ),
        ),
      ),
    );
  }
}
