part of 'signal_list_view.dart';

/// Which Audio Routing section is showing (Sheeran INPUT / TRACK / OUTPUT).
enum _SignalSection { input, track, output }

/// Persistent left sidebar + single content pane (Sheeran Audio Routing IA).
class _SignalRouterShell extends StatelessWidget {
  const _SignalRouterShell({
    required this.section,
    required this.onSelect,
    required this.panes,
  });

  final _SignalSection section;
  final ValueChanged<_SignalSection> onSelect;
  final List<_Pane> panes;

  @override
  Widget build(BuildContext context) {
    final index = section.index.clamp(0, panes.length - 1);
    return Row(
      key: const Key('signalList_sidebar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SignalSidebar(
          section: section,
          counts: [for (final p in panes) p.count],
          onSelect: onSelect,
        ),
        Expanded(child: panes[index].body()),
      ],
    );
  }
}

class _SignalSidebar extends StatelessWidget {
  const _SignalSidebar({
    required this.section,
    required this.counts,
    required this.onSelect,
  });

  final _SignalSection section;
  final List<int> counts;
  final ValueChanged<_SignalSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final items = <(_SignalSection, IconData, String)>[
      (_SignalSection.input, Icons.login, l10n.signalNavInput),
      (_SignalSection.track, Icons.graphic_eq, l10n.signalNavTrack),
      (_SignalSection.output, Icons.logout, l10n.signalNavOutput),
    ];
    return Container(
      width: 96,
      decoration: BoxDecoration(
        color: surface.chromeBar,
        border: Border(right: BorderSide(color: surface.line)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          for (var i = 0; i < items.length; i++)
            _SidebarTab(
              sectionKey: items[i].$1.name,
              selected: section == items[i].$1,
              icon: items[i].$2,
              label: items[i].$3,
              count: i < counts.length ? counts[i] : 0,
              onTap: () => onSelect(items[i].$1),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _SidebarTab extends StatelessWidget {
  const _SidebarTab({
    required this.sectionKey,
    required this.selected,
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final String sectionKey;
  final bool selected;
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final fg = selected ? surface.accent : surface.textTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Material(
        color: selected
            ? surface.accent.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: Key('signalNav_$sectionKey'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
            child: Column(
              children: [
                Icon(icon, size: 22, color: fg),
                const SizedBox(height: 6),
                Text(
                  label.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: signalLabel(
                    color: fg,
                    size: 10,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$count',
                  style: signalMono(color: surface.textTertiary, size: 9),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A pane = a mono header + a list/column body for the selected sidebar section.
abstract class _Pane extends StatelessWidget {
  const _Pane();

  String header(AppLocalizations l10n);
  int get count;
  List<Widget> children(BuildContext context);

  /// Scrolling body for the sidebar shell (no duplicate section header — the
  /// left nav already names the section).
  Widget body() => Builder(
    builder: (context) => ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      children: children(context),
    ),
  );

  @override
  Widget build(BuildContext context) => body();
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
  Widget body() => Builder(
    builder: (context) => ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      itemCount: rows.inputs.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final r = rows.inputs[i];
        return SizedBox(
          width: 280,
          child: _TraceDim(
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
        );
      },
    ),
  );

  @override
  List<Widget> children(BuildContext context) => const [];
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

/// Sheeran-style Live Signal control: one large button that cycles modes.
class _LiveSignalButton extends StatelessWidget {
  const _LiveSignalButton({
    required this.track,
    required this.mode,
    required this.onCycle,
  });

  final int track;
  final LiveSignalMode mode;
  final VoidCallback onCycle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final label = switch (mode) {
      LiveSignalMode.off => l10n.fxPageLiveSignalOff,
      LiveSignalMode.auto => l10n.fxPageLiveSignalAuto,
      LiveSignalMode.on => l10n.fxPageLiveSignalOn,
    };
    final Color fill;
    final Color fg;
    switch (mode) {
      case LiveSignalMode.auto:
        fill = surface.warning.withValues(alpha: 0.85);
        fg = surface.background;
      case LiveSignalMode.on:
        fill = surface.accent;
        fg = surface.background;
      case LiveSignalMode.off:
        fill = surface.cardHigh;
        fg = surface.textSecondary;
    }
    return Tooltip(
      message: l10n.signalLiveSignalTooltip,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: Key('signalLiveSignal_$track'),
          onTap: onCycle,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
            child: Column(
              children: [
                Text(
                  l10n.fxPageLiveSignal.toUpperCase(),
                  style: signalLabel(
                    color: fg.withValues(alpha: 0.85),
                    size: 9,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: signalMono(
                    color: fg,
                    size: 15,
                    weight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
    required this.onCycleLiveSignal,
    required this.onFocusLiveSignal,
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

  /// Cycles Live Signal Off → Auto → On for a track.
  final ValueChanged<TrackGroup> onCycleLiveSignal;

  /// Pushes Live Signal Auto focus when a track column is selected.
  final ValueChanged<int> onFocusLiveSignal;

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
  Widget body() => Builder(
    builder: (context) {
      final surface = context.surface;
      final l10n = context.l10n;
      if (rows.tracks.isEmpty) {
        return Center(
          child: Text(
            l10n.signalNotRouted,
            style: signalLabel(color: surface.textTertiary),
          ),
        );
      }
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        itemCount: rows.tracks.length,
        separatorBuilder: (_, _) => Container(
          width: 1,
          margin: const EdgeInsets.symmetric(vertical: 8),
          color: surface.line,
        ),
        itemBuilder: (context, i) {
          final g = rows.tracks[i];
          return SizedBox(
            width: 300,
            child: _TrackColumn(
              group: g,
              trackLabel: _trackLabel(l10n, g.track),
              inputCount: rows.inputCount,
              outputCount: rows.outputCount,
              trace: trace,
              selectedTake: selectedTake,
              onTap: onTap,
              onToggleRoute: onToggleRoute,
              onReassignInput: onReassignInput,
              onEditFx: onEditFx,
              onMuteToggled: onMuteToggled,
              onVolumeChanged: onVolumeChanged,
              onAddLane: onAddLane,
              onRemoveLane: onRemoveLane,
              onCycleLiveSignal: () => onCycleLiveSignal(g),
              onFocusLiveSignal: () => onFocusLiveSignal(g.track),
            ),
          );
        },
      );
    },
  );

  @override
  List<Widget> children(BuildContext context) => const [];
}

class _TrackColumn extends StatelessWidget {
  const _TrackColumn({
    required this.group,
    required this.trackLabel,
    required this.inputCount,
    required this.outputCount,
    required this.trace,
    required this.selectedTake,
    required this.onTap,
    required this.onToggleRoute,
    required this.onReassignInput,
    required this.onEditFx,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.onAddLane,
    required this.onRemoveLane,
    required this.onCycleLiveSignal,
    required this.onFocusLiveSignal,
  });

  final TrackGroup group;
  final String trackLabel;
  final int inputCount;
  final int outputCount;
  final TraceState trace;
  final ({int track, int lane})? selectedTake;
  final ValueChanged<TakeRow> onTap;
  final void Function(TakeRow take, int output) onToggleRoute;
  final void Function(TakeRow take, int input) onReassignInput;
  final ValueChanged<TakeRow> onEditFx;
  final ValueChanged<TakeRow> onMuteToggled;
  final void Function(TakeRow take, double volume) onVolumeChanged;
  final ValueChanged<int> onAddLane;
  final ValueChanged<int> onRemoveLane;
  final VoidCallback onCycleLiveSignal;
  final VoidCallback onFocusLiveSignal;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final laneCount = group.takes.length;
    final controls = _LaneControls(
      track: group.track,
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
        trackLabel: trackLabel,
        asTrack: group.single,
        inputCount: inputCount,
        outputCount: outputCount,
        selected:
            selectedTake?.track == t.track && selectedTake?.lane == t.laneIndex,
        onTap: () {
          onFocusLiveSignal();
          onTap(t);
        },
        onToggleRoute: (o) => onToggleRoute(t, o),
        onReassignInput: (i) => onReassignInput(t, i),
        onEditFx: () => onEditFx(t),
        onMuteToggled: () => onMuteToggled(t),
        onVolumeChanged: (v) => onVolumeChanged(t, v),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Icon(Icons.graphic_eq, size: 16, color: surface.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  trackLabel,
                  style: signalMono(
                    color: surface.textPrimary,
                    size: 13,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              if (!group.single)
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
                    l10n.signalTakesCount(group.takes.length),
                    style: signalMono(
                      color: surface.textTertiary,
                      size: 9,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final t in group.takes) takeRow(t),
              Align(alignment: Alignment.centerLeft, child: controls),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _LiveSignalButton(
          track: group.track,
          mode: group.liveSignal,
          onCycle: () {
            onFocusLiveSignal();
            onCycleLiveSignal();
          },
        ),
      ],
    );
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
  Widget body() => Builder(
    builder: (context) {
      final l10n = context.l10n;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (noActiveOutputs)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: _NoActiveOutputsNotice(
                message: l10n.noActiveOutputsNotice,
              ),
            ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
              itemCount: rows.outputs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final o = rows.outputs[i];
                return SizedBox(
                  width: 280,
                  child: _TraceDim(
                    trace: trace,
                    tags: o.tags,
                    child: _OutputRow(
                      row: o,
                      inputs: rows.inputsFeeding(o.output),
                      tracks: rows.tracksFeeding(o.output),
                      trackNames: trackNames,
                      selected: tracedOutput == o.output,
                      onTap: () => onTapRow(o.output),
                      onToggleGate: () =>
                          onToggleGate(o.output, enabled: !o.enabled),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );

  @override
  List<Widget> children(BuildContext context) => const [];
}
