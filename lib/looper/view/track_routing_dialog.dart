import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/track_routing_panel.dart';

/// Opens the per-track I/O routing dialog for [channel].
///
/// Dispatches routing changes to the [LooperBloc] (which forwards them to the
/// engine and persists them). Shared by the desktop looper view and the Big
/// Picture performance view so both surfaces drive routing identically. The
/// caller's [context] must be within the [LooperBloc] provider scope.
Future<void> showTrackRoutingDialog({
  required BuildContext context,
  required int channel,
}) {
  final bloc = context.read<LooperBloc>();
  return showDialog<void>(
    context: context,
    builder: (_) => BlocProvider.value(
      value: bloc,
      child: AlertDialog(
        key: const Key('trackRouting_dialog'),
        title: Text('Track ${channel + 1} routing'),
        content: BlocBuilder<LooperBloc, LooperState>(
          builder: (context, state) {
            final current = channel < state.tracks.length
                ? state.tracks[channel]
                : Track(channel: channel);
            return TrackRoutingPanel(
              track: current,
              inputChannels: state.status.inputChannels,
              outputChannels: state.status.outputChannels,
              excludedInputMask: state.status.excludedInputMask,
              onInputMaskChanged: (mask) =>
                  bloc.add(LooperInputMaskChanged(channel, mask)),
              onOutputMaskChanged: (mask) =>
                  bloc.add(LooperOutputMaskChanged(channel, mask)),
            );
          },
        ),
        actions: [
          TextButton(
            key: const Key('trackRouting_done_button'),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}
