import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_rack.dart';
import 'package:loopy/looper/view/signal_graph/signal_knob.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The mix control shared by both docks: a mute toggle next to the rotary
/// volume [SignalKnob]. Keyed off [keyPrefix] so each dock keeps its namespace.
class _MixControl extends StatelessWidget {
  const _MixControl({
    required this.keyPrefix,
    required this.muted,
    required this.volume,
    required this.onMuteToggled,
    required this.onVolumeChanged,
  });

  final String keyPrefix;
  final bool muted;
  final double volume;
  final VoidCallback onMuteToggled;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          key: Key('${keyPrefix}_mute'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          iconSize: 18,
          color: muted ? surface.accent : surface.textSecondary,
          tooltip: muted ? l10n.unmuteInputTooltip : l10n.muteInputTooltip,
          icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
          onPressed: onMuteToggled,
        ),
        const SizedBox(width: 6),
        SignalKnob(
          knobKey: Key('${keyPrefix}_volume'),
          value: muted ? 0 : volume,
          max: kSignalMaxGain,
          resetValue: 1,
          snapTargets: const [1], // catch at unity (0 dB)
          onChanged: onVolumeChanged,
          label: l10n.signalVolumeLabel,
          color: surface.accent,
        ),
      ],
    );
  }
}

/// A mono "context" tag for the dock header — `INPUT` / `TAKE` — so it always
/// reads what kind of thing is focused.
class _ContextTag extends StatelessWidget {
  const _ContextTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label.toUpperCase(),
        style: signalMono(color: color, size: 9.5, tracking: 1.6),
      ),
    );
  }
}

/// The bottom dock for the **focused input**: its single live FX chain's
/// selected-effect editor, mix, and a Stop that disables monitoring. The tone
/// here is what records onto a take (snapshot-on-record).
class SignalInputDock extends StatelessWidget {
  /// Creates a [SignalInputDock].
  const SignalInputDock({
    required this.input,
    required this.monitor,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.onStop,
    required this.onAddEffect,
    required this.onSetType,
    required this.onSetParam,
    required this.onSetPluginParam,
    required this.onRemoveEffect,
    required this.onReorderEffect,
    super.key,
  });

  /// The focused hardware input.
  final int input;

  /// Its live-monitor configuration (gate + chain + routing + mix).
  final InputMonitor monitor;

  final VoidCallback onMuteToggled;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onStop;
  final VoidCallback onAddEffect;
  final void Function(int index, TrackEffectType type) onSetType;
  final void Function(int index, int param, double value) onSetParam;
  final void Function(int index, int paramId, double value) onSetPluginParam;
  final ValueChanged<int> onRemoveEffect;
  final void Function(int oldIndex, int newIndex) onReorderEffect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return _DockShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _ContextTag(
                label: l10n.signalContextInput,
                color: surface.accent,
              ),
              const SizedBox(width: 10),
              Text(
                l10n.inputMonitorLabel(input + 1),
                style: signalMono(
                  color: surface.textPrimary,
                  size: 13,
                  tracking: 0.5,
                  weight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('signalGraph_stop'),
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: Text(
                  l10n.stopButton,
                  style: signalMono(color: surface.textSecondary),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: surface.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MixControl(
                keyPrefix: 'signalGraph',
                muted: monitor.muted,
                volume: monitor.volume,
                onMuteToggled: onMuteToggled,
                onVolumeChanged: onVolumeChanged,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: SignalFxRack(
                  keyPrefix: 'signalGraph_input',
                  effects: monitor.effects,
                  onAddEffect: onAddEffect,
                  onRemoveEffect: onRemoveEffect,
                  onSetType: onSetType,
                  onSetParam: onSetParam,
                  onSetPluginParam: onSetPluginParam,
                  onReorder: onReorderEffect,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The bottom dock for a **focused lane**: the "this take" editor. The lane's
/// FX is the snapshot taken at record; editing it here changes
/// only this lane, never the live input or other takes (D10).
class SignalLaneDock extends StatelessWidget {
  /// Creates a [SignalLaneDock].
  const SignalLaneDock({
    required this.inputNumber,
    required this.effects,
    required this.muted,
    required this.volume,
    required this.onAddEffect,
    required this.onRemoveEffect,
    required this.onSetType,
    required this.onSetParam,
    required this.onSetPluginParam,
    required this.onReorderEffect,
    required this.onMuteToggled,
    required this.onVolumeChanged,
    required this.canAddLane,
    required this.canRemoveLane,
    required this.onAddLane,
    required this.onRemoveLane,
    super.key,
  });

  /// The 1-based input this lane captured (for the snapshot label), or 0 if the
  /// lane records nothing.
  final int inputNumber;

  /// Whether the track can gain another lane (below the per-track cap).
  final bool canAddLane;

  /// Whether this lane can be removed (it is the track's last, count > 1).
  final bool canRemoveLane;

  final VoidCallback onAddLane;
  final VoidCallback onRemoveLane;

  /// The lane's effect chain (the snapshot, in processing order).
  final List<TrackEffect> effects;

  final bool muted;
  final double volume;
  final VoidCallback onAddEffect;
  final ValueChanged<int> onRemoveEffect;
  final void Function(int index, TrackEffectType type) onSetType;
  final void Function(int index, int param, double value) onSetParam;
  final void Function(int index, int paramId, double value) onSetPluginParam;
  final void Function(int oldIndex, int newIndex) onReorderEffect;
  final VoidCallback onMuteToggled;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return _DockShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _ContextTag(label: l10n.signalContextTake, color: surface.accent),
              const SizedBox(width: 10),
              if (inputNumber > 0)
                Container(
                  key: const Key('signalGraph_thisTakeBadge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: surface.accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: surface.accent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 12, color: surface.accent),
                      const SizedBox(width: 6),
                      Text(
                        l10n.signalThisTakeLabel(inputNumber),
                        style: signalMono(color: surface.accent),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              IconButton(
                key: const Key('signalGraph_removeLane'),
                iconSize: 18,
                color: surface.textSecondary,
                tooltip: l10n.removeLaneTooltip,
                icon: const Icon(Icons.layers_clear),
                onPressed: canRemoveLane ? onRemoveLane : null,
              ),
              TextButton.icon(
                key: const Key('signalGraph_addLane'),
                onPressed: canAddLane ? onAddLane : null,
                icon: const Icon(Icons.add, size: 18),
                label: Text(
                  l10n.addLane,
                  style: signalMono(color: surface.textSecondary),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: surface.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            effects.isEmpty
                ? l10n.signalLaneCleanHint
                : l10n.signalThisTakeHint,
            style: signalMono(color: surface.textSecondary, size: 11.5),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MixControl(
                keyPrefix: 'signalGraph_lane',
                muted: muted,
                volume: volume,
                onMuteToggled: onMuteToggled,
                onVolumeChanged: onVolumeChanged,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: SignalFxRack(
                  keyPrefix: 'signalGraph_lane',
                  effects: effects,
                  onAddEffect: onAddEffect,
                  onRemoveEffect: onRemoveEffect,
                  onSetType: onSetType,
                  onSetParam: onSetParam,
                  onSetPluginParam: onSetPluginParam,
                  onReorder: onReorderEffect,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The shared docked container — a gradient panel with a top border, the way
/// the mockup's editor tray sits below the canvas.
class _DockShell extends StatelessWidget {
  const _DockShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0F0F15), Color(0xFF0C0C10)],
        ),
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: child,
    );
  }
}

/// A hint shown when nothing is focused.
class SignalHintDock extends StatelessWidget {
  /// Creates a [SignalHintDock].
  const SignalHintDock({required this.message, super.key});

  /// The hint text.
  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return _DockShell(
      child: Row(
        children: [
          Icon(Icons.touch_app_outlined, size: 16, color: surface.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: signalMono(color: surface.textSecondary, size: 12),
            ),
          ),
        ],
      ),
    );
  }
}
