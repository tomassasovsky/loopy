part of 'signal_list_view.dart';

/// The narrow-screen layout: the three columns become **tabs** so each list
/// gets the full width, rather than a tall single-column stack.
class _SignalTabs extends StatelessWidget {
  const _SignalTabs({required this.panes});

  final List<_Pane> panes;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return DefaultTabController(
      length: panes.length,
      child: Column(
        key: const Key('signalList_tabbed'),
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: surface.line)),
            ),
            child: TabBar(
              labelColor: surface.accent,
              unselectedLabelColor: surface.textTertiary,
              indicatorColor: surface.accent,
              dividerColor: Colors.transparent,
              labelStyle: signalLabel(
                color: surface.accent,
                weight: FontWeight.w600,
              ),
              unselectedLabelStyle: signalLabel(color: surface.textTertiary),
              tabs: [
                for (final p in panes)
                  Tab(
                    height: 42,
                    text: '${p.header(l10n).toUpperCase()}  ·  ${p.count}',
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(children: [for (final p in panes) p.body()]),
          ),
        ],
      ),
    );
  }
}

/// A pane = a mono header + a list body, shown side-by-side on a wide window
/// (via [build]) or as a tab body on a narrow one (via [body]).
abstract class _Pane extends StatelessWidget {
  const _Pane();

  String header(AppLocalizations l10n);
  int get count;
  List<Widget> children(BuildContext context);

  /// The pane's scrolling body alone — no header or divider — for the tabbed
  /// narrow layout, where the tab already names (and counts) the column.
  Widget body() => Builder(
    builder: (context) => ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      children: children(context),
    ),
  );

  @override
  Widget build(BuildContext context) => _PaneShell(pane: this);
}

class _PaneShell extends StatelessWidget {
  const _PaneShell({required this.pane});

  final _Pane pane;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
      children: pane.children(context),
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: surface.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 13, 18, 9),
            child: Row(
              children: [
                Text(
                  pane.header(l10n).toUpperCase(),
                  style: signalLabel(
                    color: surface.textTertiary,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: surface.cardHigh,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: surface.line),
                  ),
                  child: Text(
                    '${pane.count}',
                    style: signalMono(color: surface.textSecondary, size: 9),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: list),
        ],
      ),
    );
  }
}

/// Wraps a row so the whole row dims when a trace is active and it is not lit;
/// the dimmed row stays focusable + in the semantics tree (visual only).
class _TraceDim extends StatelessWidget {
  const _TraceDim({
    required this.trace,
    required this.tags,
    required this.child,
  });

  final TraceState trace;
  final Set<String> tags;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dim = trace.active && !trace.lit(tags);
    return AnimatedOpacity(
      opacity: dim ? 0.28 : 1,
      duration: Durations.short3,
      child: child,
    );
  }
}

// --- Panes ---------------------------------------------------------------

class _InputsPane extends _Pane {
  const _InputsPane({
    required this.rows,
    required this.trace,
    required this.selectedInput,
    required this.onTap,
    required this.onToggleRoute,
    required this.onToggleGate,
    required this.onEditFx,
    required this.onMuteToggled,
    required this.onVolumeChanged,
  });

  final SignalRows rows;
  final TraceState trace;
  final int? selectedInput;
  final ValueChanged<InputRow> onTap;
  final void Function(int input, int output) onToggleRoute;
  final ValueChanged<int> onToggleGate;
  final ValueChanged<int> onEditFx;
  final ValueChanged<int> onMuteToggled;
  final void Function(int input, double volume) onVolumeChanged;

  @override
  String header(AppLocalizations l10n) => l10n.signalSectionInputs;

  @override
  int get count => rows.inputs.length;

  @override
  List<Widget> children(BuildContext context) => [
    for (final r in rows.inputs)
      _TraceDim(
        trace: trace,
        tags: r.tags,
        child: _InputRow(
          row: r,
          outputCount: rows.outputCount,
          selected: selectedInput == r.input,
          onTap: () => onTap(r),
          onToggleRoute: (o) => onToggleRoute(r.input, o),
          onToggleGate: () => onToggleGate(r.input),
          onEditFx: () => onEditFx(r.input),
          onMuteToggled: () => onMuteToggled(r.input),
          onVolumeChanged: (v) => onVolumeChanged(r.input, v),
        ),
      ),
  ];
}

/// The add/remove-lane controls for a track — relocated onto the routing
/// surface from the old lane dock. Add is disabled at the per-track cap; the
/// remove-last-lane action only shows when the track has more than one lane.
class _LaneControls extends StatelessWidget {
  const _LaneControls({
    required this.track,
    required this.canAdd,
    required this.canRemove,
    required this.onAddLane,
    required this.onRemoveLane,
  });

  final int track;
  final bool canAdd;
  final bool canRemove;
  final ValueChanged<int> onAddLane;
  final ValueChanged<int> onRemoveLane;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canRemove)
          IconButton(
            key: Key('signalGraph_removeLane_$track'),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            iconSize: 17,
            color: surface.textSecondary,
            tooltip: l10n.removeLaneTooltip,
            icon: const Icon(Icons.layers_clear),
            onPressed: () => onRemoveLane(track),
          ),
        TextButton.icon(
          key: Key('signalGraph_addLane_$track'),
          onPressed: canAdd ? () => onAddLane(track) : null,
          icon: const Icon(Icons.add, size: 16),
          label: Text(
            l10n.addLane,
            style: signalLabel(color: surface.textSecondary),
          ),
          style: TextButton.styleFrom(
            foregroundColor: surface.textSecondary,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    );
  }
}

class _TracksPane extends _Pane {
  const _TracksPane({
    required this.rows,
    required this.trace,
    required this.selectedTake,
    required this.trackNames,
    required this.onTap,
    required this.onToggleRoute,
    required this.onReassignInput,
    required this.onEditFx,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.onAddLane,
    required this.onRemoveLane,
  });

  final SignalRows rows;
  final TraceState trace;
  final ({int track, int lane})? selectedTake;
  final List<String> trackNames;
  final ValueChanged<TakeRow> onTap;
  final void Function(TakeRow take, int output) onToggleRoute;
  final void Function(TakeRow take, int input) onReassignInput;
  final ValueChanged<TakeRow> onEditFx;
  final ValueChanged<TakeRow> onMuteToggled;
  final void Function(TakeRow take, double volume) onVolumeChanged;

  /// Adds a lane to the given track (below the per-track cap).
  final ValueChanged<int> onAddLane;

  /// Removes the given track's last lane (when it has more than one).
  final ValueChanged<int> onRemoveLane;

  @override
  String header(AppLocalizations l10n) => l10n.signalSectionTracks;

  @override
  int get count => rows.tracks.length;

  /// The track's display name (custom or `Track N`).
  String _trackLabel(AppLocalizations l10n, int track) =>
      track < trackNames.length
      ? l10n.displayTrackName(trackNames[track], track)
      : l10n.trackNumberLabel(track + 1);

  @override
  List<Widget> children(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final out = <Widget>[];
    for (final g in rows.tracks) {
      final laneCount = g.takes.length;
      final controls = _LaneControls(
        track: g.track,
        canAdd: laneCount < kMaxLanes,
        canRemove: laneCount > 1,
        onAddLane: onAddLane,
        onRemoveLane: onRemoveLane,
      );
      Widget takeRow(TakeRow t) => _TraceDim(
        trace: trace,
        tags: t.tags,
        child: _TakeRow(
          take: t,
          trackLabel: _trackLabel(l10n, t.track),
          asTrack: g.single,
          inputCount: rows.inputCount,
          outputCount: rows.outputCount,
          selected:
              selectedTake?.track == t.track &&
              selectedTake?.lane == t.laneIndex,
          onTap: () => onTap(t),
          onToggleRoute: (o) => onToggleRoute(t, o),
          onReassignInput: (i) => onReassignInput(t, i),
          onEditFx: () => onEditFx(t),
          onMuteToggled: () => onMuteToggled(t),
          onVolumeChanged: (v) => onVolumeChanged(t, v),
        ),
      );
      if (g.single) {
        // A single-lane track is its own card; its add-lane control sits just
        // under the row (there is no track header to carry it).
        out.add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [takeRow(g.takes.first), controls],
          ),
        );
      } else {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // .trk-h: track name + a bordered "N takes" count badge +
                // the add/remove-lane controls (relocated off the old dock).
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 7),
                  child: Row(
                    children: [
                      Text(
                        _trackLabel(l10n, g.track),
                        style: signalMono(
                          color: surface.textPrimary,
                          size: 13,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: surface.line),
                        ),
                        child: Text(
                          l10n.signalTakesCount(g.takes.length),
                          style: signalMono(
                            color: surface.textTertiary,
                            size: 9,
                          ),
                        ),
                      ),
                      const Spacer(),
                      controls,
                    ],
                  ),
                ),
                // .take: nested takes hang off a left rule.
                Container(
                  margin: const EdgeInsets.only(left: 10),
                  padding: const EdgeInsets.only(left: 10),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: surface.line)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final t in g.takes) takeRow(t)],
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    return out;
  }
}

class _OutputsPane extends _Pane {
  const _OutputsPane({
    required this.rows,
    required this.trace,
    required this.noActiveOutputs,
    required this.tracedOutput,
    required this.trackNames,
    required this.onTapRow,
    required this.onToggleGate,
  });

  final SignalRows rows;
  final TraceState trace;
  final bool noActiveOutputs;
  final int? tracedOutput;
  final List<String> trackNames;
  final ValueChanged<int> onTapRow;
  final void Function(int output, {required bool enabled}) onToggleGate;

  @override
  String header(AppLocalizations l10n) => l10n.signalSectionOutputs;

  @override
  int get count => rows.outputs.length;

  @override
  List<Widget> children(BuildContext context) {
    final l10n = context.l10n;
    return [
      if (noActiveOutputs)
        _NoActiveOutputsNotice(message: l10n.noActiveOutputsNotice),
      for (final o in rows.outputs)
        _TraceDim(
          trace: trace,
          tags: o.tags,
          child: _OutputRow(
            row: o,
            inputs: rows.inputsFeeding(o.output),
            tracks: rows.tracksFeeding(o.output),
            trackNames: trackNames,
            selected: tracedOutput == o.output,
            onTap: () => onTapRow(o.output),
            onToggleGate: () => onToggleGate(o.output, enabled: !o.enabled),
          ),
        ),
    ];
  }
}
