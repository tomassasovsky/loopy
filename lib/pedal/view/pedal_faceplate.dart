import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_view.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/pedal/view/pedal_plate.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/widgets/waveform_view.dart';

/// The on-screen pedal simulator: a replica of the Segno top plate — the two
/// screen apertures (a 7" waveform on the left, the main [TracksView] on
/// the right), the encoder + activity ring, and the footswitches, laid out to
/// scale from the 3D model. It drives the **real** `PedalCubit` (through
/// [SimulatorPedalTransport]) and renders the LED feedback it projects, so the
/// looper can be performed exactly as it would on the hardware.
///
/// Shown by the looper page only while the on-screen pedal is the bound
/// output. The actual plate rendering lives in [PedalPlate]; this widget is
/// the thin simulator wrapper — transport wiring, the bound-output gate, and
/// the looper screen chrome.
class PedalFaceplate extends StatefulWidget {
  /// Creates a [PedalFaceplate].
  ///
  /// [mainScreen] and [waveformScreen] fill the two screen apertures; they
  /// default to the real [TracksView] and the live output waveform, and are
  /// injectable so widget tests can substitute simple placeholders.
  const PedalFaceplate({this.mainScreen, this.waveformScreen, super.key});

  /// The widget in the large (main) screen aperture. Defaults to
  /// [TracksView].
  final Widget? mainScreen;

  /// The widget in the small (7") screen aperture. Defaults to the live output
  /// waveform.
  final Widget? waveformScreen;

  @override
  State<PedalFaceplate> createState() => _PedalFaceplateState();
}

class _PedalFaceplateState extends State<PedalFaceplate> {
  late SimulatorPedalTransport _sim;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sim = context.read<SimulatorPedalTransport>();
  }

  @override
  void deactivate() {
    _sim.releaseAll(); // never leave a note (or the cubit's undo timer) stuck
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    // The plate is shown only while the on-screen pedal is the bound output;
    // otherwise the main screen renders full-screen as usual. The mount is the
    // sole gate — footswitches don't exist when the plate is hidden, so
    // on-screen input is unreachable then.
    final onScreenPedal = context.select<PedalCubit, bool>(
      (cubit) => cubit.state.boundOutputId == kSimulatorOutputId,
    );
    if (!onScreenPedal) return widget.mainScreen ?? const TracksView();
    // Embedded in the plate's screen: just the four track bars (TrackMeterRow),
    // no chrome — the pedal supplies every control.
    final mainScreen = LooperScreenTheme(
      child: widget.mainScreen ?? const TrackMeterRow(),
    );
    return Material(
      color: context.surface.background,
      child: SafeArea(
        child: Padding(
          key: const Key('pedalFaceplate'),
          padding: const EdgeInsets.all(12),
          child: ValueListenableBuilder<PedalStateFrame>(
            valueListenable: _sim.frame,
            builder: (context, frame, _) => PedalPlate(
              frame: frame,
              onPress: _sim.press,
              onTurn: _sim.turn,
              // What the switches DO comes from the live interaction mode, not
              // from the frame: the wire mode is downgraded for a pre-v3 pedal
              // (fx encodes as play), so labelling from it would describe
              // mute-mode meanings while the foot is driving FX actions.
              mode: context.select<ControlCubit, InteractionMode>(
                (cubit) => cubit.state.mode,
              ),
              l10n: context.l10n,
              mainScreen: mainScreen,
              waveformScreen: widget.waveformScreen ?? const _ScreenWaveform(),
              onClose: () => context.read<PedalCubit>().selectNone(),
            ),
          ),
        ),
      ),
    );
  }
}

/// The live output waveform in the 7" aperture, polled from the looper on a
/// display-rate timer (mirrors what the waveform sub-window is fed).
class _ScreenWaveform extends StatefulWidget {
  const _ScreenWaveform();

  @override
  State<_ScreenWaveform> createState() => _ScreenWaveformState();
}

class _ScreenWaveformState extends State<_ScreenWaveform> {
  static const _tick = Duration(milliseconds: 33);
  Timer? _timer;
  Float32List _samples = Float32List(0);
  double _progress = 0;
  String _selectedTrack = '';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tick, (_) => _poll());
  }

  void _poll() {
    if (!mounted) return;
    final looper = context.read<LooperRepository>();
    final tracks = context.read<TracksCubit>();
    setState(() {
      _samples = looper.readWaveform();
      _progress = looper.state.transport.progress;
      _selectedTrack = tracks.state.nameOf(
        context.read<ControlCubit>().state.cursor,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: WaveformView(
        samples: _samples,
        progress: _progress,
        selectedTrack: _selectedTrack,
      ),
    );
  }
}
