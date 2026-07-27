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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('fx_page'),
          backgroundColor: context.surface.background,
          body: SafeArea(
            child: Column(
              children: [
                _FxChromeBar(),
                const Expanded(child: _FxBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FxChromeBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          IconButton(
            key: const Key('fx_page_back'),
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
            icon: const Icon(Icons.arrow_back),
          ),
          Text(
            l10n.fxPageTitle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: surface.textPrimary,
            ),
          ),
          const Spacer(),
          TextButton(
            key: const Key('fx_page_presets'),
            onPressed: () => unawaited(_showPresets(context)),
            child: Text(l10n.fxPagePresets),
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
      children: [
        Expanded(
          child: _FxColumn(
            title: l10n.fxPageInputColumn,
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
        VerticalDivider(width: 1, color: context.surface.line),
        Expanded(
          child: _FxColumn(
            title: l10n.fxPageTrackColumn,
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
    required this.selector,
    required this.stage,
    required this.onStage,
    required this.scope,
  });

  final String title;
  final Widget selector;
  final FxStage stage;
  final ValueChanged<FxStage> onStage;
  final FxScope scope;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        selector,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SegmentedButton<FxStage>(
            segments: [
              ButtonSegment(
                value: FxStage.pre,
                label: Text(l10n.fxPagePre),
                icon: const Icon(Icons.input),
              ),
              ButtonSegment(
                value: FxStage.post,
                label: Text(l10n.fxPagePost),
                icon: const Icon(Icons.output),
              ),
            ],
            selected: {stage},
            onSelectionChanged: (s) => onStage(s.single),
          ),
        ),
        Expanded(
          child: FxDock(
            key: ValueKey('${scope.runtimeType}-$stage'),
            scope: scope,
            onClose: () {},
          ),
        ),
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
    if (count <= 0) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selectedChip = i == selected;
          return ChoiceChip(
            key: Key('fx_select_$i'),
            label: Text(labelOf(i)),
            selected: selectedChip,
            onSelected: (_) => onSelect(i),
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
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      final factory = library.factoryPresets;
      final user = library.userPresets;
      return SafeArea(
        child: ListView(
          children: [
            ListTile(title: Text(l10n.fxPageFactoryPresets)),
            for (final preset in factory)
              ListTile(
                key: Key('fx_preset_${preset.id}'),
                title: Text(preset.name),
                subtitle: Text(preset.category),
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
            ListTile(title: Text(l10n.fxPageUserPresets)),
            for (final preset in user)
              ListTile(
                title: Text(preset.name),
                onTap: () {
                  fx.setTrackEffects(preset.toEffects());
                  Navigator.pop(sheetContext);
                },
              ),
            ListTile(
              key: const Key('fx_preset_save'),
              leading: const Icon(Icons.save_outlined),
              title: Text(l10n.fxPageSavePreset),
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
