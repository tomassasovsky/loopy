import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/fx_racks_cubit.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/fx_presets/fx_preset.dart';
import 'package:loopy/looper/fx_presets/fx_preset_library.dart';
import 'package:loopy/looper/view/fx_editor/fx_dock.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/page_transitions.dart';
import 'package:loopy/theme/surface_theme.dart';

/// Opens the dedicated **FX** page (Input | Track Pre/Post racks + presets).
/// Live Signal lives on Signal → Track (Sheeran Audio Routing placement).
Future<void> showFxPage(BuildContext context) {
  final bloc = context.read<LooperBloc>();
  final monitor = context.read<MonitorCubit>();
  final tracks = context.read<TracksCubit>();
  final repository = context.read<LooperRepository>();
  return Navigator.of(context).push(
    desktopPageRoute<void>(
      (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: bloc),
          BlocProvider.value(value: monitor),
          BlocProvider.value(value: tracks),
          BlocProvider(
            create: (_) => FxRacksCubit(repository: repository)..selectTrack(0),
          ),
        ],
        child: RepositoryProvider.value(
          value: repository,
          child: const FxPage(),
        ),
      ),
    ),
  );
}

/// Dedicated FX racks page: Input column | Track column with Pre/Post only.
class FxPage extends StatelessWidget {
  /// Creates an [FxPage].
  const FxPage({super.key});

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('fx_page'),
          backgroundColor: surface.background,
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.5, -1.15),
                radius: 1.25,
                colors: [surface.pageGlow, surface.background],
                stops: const [0, 0.62],
              ),
            ),
            child: const SafeArea(
              child: Column(
                children: [
                  _FxChromeBar(),
                  Expanded(child: _FxBody()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FxChromeBar extends StatelessWidget {
  const _FxChromeBar();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.line)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [surface.chromeGradientTop, surface.chromeGradientBottom],
        ),
      ),
      child: Row(
        children: [
          TextButton.icon(
            key: const Key('fx_page_back'),
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
            icon: const Icon(Icons.chevron_left, size: 18),
            label: Text(
              l10n.close,
              style: signalLabel(color: surface.textSecondary),
            ),
            style: TextButton.styleFrom(
              foregroundColor: surface.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.fxPageTitle.toUpperCase(),
            style: signalLabel(
              color: surface.textPrimary,
              size: 14,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            l10n.fxPageSubtitle,
            style: signalLabel(color: surface.textTertiary),
          ),
          const Spacer(),
          TextButton(
            key: const Key('fx_page_presets'),
            onPressed: () => unawaited(_showPresets(context)),
            style: TextButton.styleFrom(
              foregroundColor: surface.accent,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: Text(
              l10n.fxPagePresets,
              style: signalLabel(
                color: surface.accent,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FxBody extends StatelessWidget {
  const _FxBody();

  @override
  Widget build(BuildContext context) {
    context
      ..watch<LooperBloc>()
      ..watch<MonitorCubit>()
      ..watch<FxRacksCubit>();
    final l10n = context.l10n;
    final surface = context.surface;
    final fx = context.read<FxRacksCubit>();
    final looper = context.read<LooperBloc>();
    final repository = context.read<LooperRepository>();
    final monitor = context.read<MonitorCubit>();
    final state = fx.state;
    final inputCount = looper.state.status.inputChannels;
    final trackCount = looper.state.tracks.length;

    final inputScope = state.inputStage == FxStage.pre
        ? InputPreFxScope(
            fxRacks: fx,
            looper: looper,
            repository: repository,
            input: state.selectedInput,
          )
        : InputFxScope(
            monitor: monitor,
            looper: looper,
            repository: repository,
            input: state.selectedInput,
          );

    final trackScope = state.trackStage == FxStage.pre
        ? TrackPreFxScope(
            fxRacks: fx,
            looper: looper,
            repository: repository,
            track: state.selectedTrack,
          )
        : TrackPostFxScope(
            fxRacks: fx,
            looper: looper,
            repository: repository,
            track: state.selectedTrack,
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _FxColumn(
            title: l10n.fxPageInputColumn,
            subtitle: l10n.fxPageInputHint,
            selector: _IndexSelector(
              count: inputCount,
              selected: state.selectedInput,
              labelOf: (i) => l10n.fxEditorInputTitle(i + 1),
              onSelect: fx.selectInput,
            ),
            stage: state.inputStage,
            onStage: fx.setInputStage,
            scope: inputScope,
          ),
        ),
        Container(width: 1, color: surface.line),
        Expanded(
          child: _FxColumn(
            title: l10n.fxPageTrackColumn,
            subtitle: l10n.fxPageTrackHint,
            selector: _IndexSelector(
              count: trackCount,
              selected: state.selectedTrack,
              labelOf: (i) => l10n.defaultTrackName(i + 1),
              onSelect: fx.selectTrack,
            ),
            stage: state.trackStage,
            onStage: fx.setTrackStage,
            scope: trackScope,
          ),
        ),
      ],
    );
  }
}

class _FxColumn extends StatelessWidget {
  const _FxColumn({
    required this.title,
    required this.subtitle,
    required this.selector,
    required this.stage,
    required this.onStage,
    required this.scope,
  });

  final String title;
  final String subtitle;
  final Widget selector;
  final FxStage stage;
  final ValueChanged<FxStage> onStage;
  final FxScope scope;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: signalLabel(
              color: surface.textPrimary,
              size: 13,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: signalLabel(color: surface.textTertiary),
          ),
          const SizedBox(height: 14),
          selector,
          const SizedBox(height: 12),
          _StageToggle(stage: stage, onStage: onStage, l10n: l10n),
          const SizedBox(height: 12),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surface.card.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: surface.line),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FxDock(
                  key: ValueKey('${scope.runtimeType}-$stage'),
                  scope: scope,
                  onClose: () {},
                  fill: true,
                  showClose: false,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StageToggle extends StatelessWidget {
  const _StageToggle({
    required this.stage,
    required this.onStage,
    required this.l10n,
  });

  final FxStage stage;
  final ValueChanged<FxStage> onStage;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    Widget chip(FxStage value, String label) {
      final selected = stage == value;
      return Expanded(
        child: Material(
          color: selected
              ? surface.accent.withValues(alpha: 0.18)
              : surface.cardHigh,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: Key('fx_stage_${value.name}'),
            onTap: () => onStage(value),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? surface.accent : surface.line,
                ),
              ),
              child: Text(
                label.toUpperCase(),
                textAlign: TextAlign.center,
                style: signalLabel(
                  color: selected ? surface.accent : surface.textSecondary,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(FxStage.pre, l10n.fxPagePre),
        const SizedBox(width: 8),
        chip(FxStage.post, l10n.fxPagePost),
      ],
    );
  }
}

class _IndexSelector extends StatelessWidget {
  const _IndexSelector({
    required this.count,
    required this.selected,
    required this.labelOf,
    required this.onSelect,
  });

  final int count;
  final int selected;
  final String Function(int) labelOf;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    if (count <= 0) {
      return Text(
        context.l10n.signalNotRouted,
        style: signalLabel(color: surface.textTertiary),
      );
    }
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selectedChip = i == selected;
          return Material(
            color: selectedChip
                ? surface.accent.withValues(alpha: 0.18)
                : surface.cardHigh,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              key: Key('fx_select_$i'),
              onTap: () => onSelect(i),
              borderRadius: BorderRadius.circular(9),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: selectedChip ? surface.accent : surface.line,
                  ),
                ),
                child: Text(
                  labelOf(i),
                  style: signalMono(
                    color: selectedChip
                        ? surface.accent
                        : surface.textSecondary,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<void> _showPresets(BuildContext context) async {
  final library = await FxPresetLibrary.load();
  if (!context.mounted) return;
  final fx = context.read<FxRacksCubit>();
  final l10n = context.l10n;
  final surface = context.surface;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: surface.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) {
      final factory = library.factoryPresets;
      final user = library.userPresets;
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                l10n.fxPageFactoryPresets.toUpperCase(),
                style: signalLabel(
                  color: surface.textTertiary,
                  weight: FontWeight.w600,
                ),
              ),
            ),
            for (final preset in factory)
              ListTile(
                key: Key('fx_preset_${preset.id}'),
                title: Text(
                  preset.name,
                  style: signalLabel(color: surface.textPrimary),
                ),
                subtitle: Text(
                  preset.category,
                  style: signalLabel(color: surface.textTertiary),
                ),
                onTap: () {
                  final effects = preset.toEffects();
                  final stage = preset.suggestedStage == 'pre'
                      ? FxStage.pre
                      : FxStage.post;
                  fx
                    ..setInputStage(stage)
                    ..setTrackStage(stage)
                    ..setTrackEffects(effects);
                  Navigator.pop(sheetContext);
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l10n.fxPageUserPresets.toUpperCase(),
                style: signalLabel(
                  color: surface.textTertiary,
                  weight: FontWeight.w600,
                ),
              ),
            ),
            for (final preset in user)
              ListTile(
                title: Text(
                  preset.name,
                  style: signalLabel(color: surface.textPrimary),
                ),
                onTap: () {
                  fx.setTrackEffects(preset.toEffects());
                  Navigator.pop(sheetContext);
                },
              ),
            ListTile(
              key: const Key('fx_preset_save'),
              leading: Icon(Icons.save_outlined, color: surface.accent),
              title: Text(
                l10n.fxPageSavePreset,
                style: signalLabel(color: surface.accent),
              ),
              onTap: () async {
                final effects = fx.trackEffects();
                await library.saveUserPreset(
                  FxPreset(
                    id: 'user_${DateTime.now().millisecondsSinceEpoch}',
                    name: 'User ${user.length + 1}',
                    category: 'User',
                    suggestedStage: fx.state.trackStage == FxStage.pre
                        ? 'pre'
                        : 'post',
                    effects: [
                      for (final e in effects)
                        if (e is BuiltInEffect)
                          FxPresetEffect(
                            type: e.type.name,
                            params: e.params,
                          ),
                    ],
                  ),
                );
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      );
    },
  );
}
