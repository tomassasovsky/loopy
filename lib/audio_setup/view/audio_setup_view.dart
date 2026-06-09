import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';

part 'audio_setup_tokens.dart';
part 'audio_setup_controls.dart';
part 'audio_setup_steps.dart';

/// Stepped audio-device setup, laid out as a wide two-pane panel: a left rail
/// with the brand, context and step list, and a right pane with the controls
/// and footer actions. Collapses to a live status panel once the device is
/// open.
class AudioSetupView extends StatefulWidget {
  /// Creates an [AudioSetupView].
  const AudioSetupView({super.key});

  @override
  State<AudioSetupView> createState() => _AudioSetupViewState();
}

class _AudioSetupViewState extends State<AudioSetupView> {
  static const _steps = ['Audio engine', 'Input', 'Ready to play'];
  int _step = 0;
  bool _forward = true;

  void _go(int next) => setState(() {
    _forward = next > _step;
    _step = next;
  });

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<AudioSetupCubit>();
    final state = cubit.state;
    final running = state.status == AudioSetupStatus.running;
    final canPop = Navigator.of(context).canPop();

    return Scaffold(
      backgroundColor: _C.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 940, maxHeight: 540),
          child: SizedBox.expand(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _C.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _C.line),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (running)
                        _RunningPanel(state: state, cubit: cubit)
                      else
                        _Wizard(
                          steps: _steps,
                          step: _step,
                          forward: _forward,
                          onGo: _go,
                          state: state,
                          cubit: cubit,
                        ),
                      if (canPop)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: IconButton(
                            key: const Key('audioSetup_close_button'),
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.close,
                              size: 18,
                              color: _C.t2,
                            ),
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
