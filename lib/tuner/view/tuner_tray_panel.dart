import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/host_page_chrome.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';

/// In-tray chromatic tuner, built to `TUNER / tuner` and `TUNER / tuner-mic`.
///
/// A rail destination rather than a full-screen takeover (#442, decision D6):
/// the tray is already near-fullscreen, so a takeover buys nothing. **Tuning
/// does not mute** — the design draws the stage playing behind, with no mute
/// control and no warning, so the console keeps going while you tune.
///
/// Stateful only to arm and disarm: detection is gated in the engine on the
/// armed input, so a tuner nobody is looking at costs one atomic load per
/// audio block. Arming here — where the face is created and disposed — is what
/// keeps that promise without a lifecycle of its own.
class TunerTrayPanel extends StatefulWidget {
  /// Creates a [TunerTrayPanel].
  const TunerTrayPanel({required this.onBack, super.key});

  /// Returns to the tray home tiles (does not dismiss the tray).
  final VoidCallback onBack;

  @override
  State<TunerTrayPanel> createState() => _TunerTrayPanelState();
}

class _TunerTrayPanelState extends State<TunerTrayPanel> {
  /// Held rather than looked up in [dispose]: by then this element is
  /// deactivated and an ancestor lookup is unsafe. Captured in
  /// [didChangeDependencies], which is the documented place to do it.
  TunerCubit? _tuner;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tuner = context.read<TunerCubit>();
    if (identical(tuner, _tuner)) return;
    _tuner = tuner;
    tuner.arm();
  }

  @override
  void dispose() {
    _tuner?.disarm();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inputs = context.watch<InputsCubit>().state;
    final (channels, excluded) = context.select<LooperRepository, (int, int)>(
      (r) => (r.state.status.inputChannels, r.state.status.excludedInputMask),
    );
    final tuner = context.watch<TunerCubit>().state;

    // Loopback captures carry the console's OWN output back (that is what the
    // engine excludes them for), and the tuner tap does not filter them — so a
    // tab for one would arm the tuner on the loop that is playing and report
    // its pitch as though something were plugged into that socket. A reading
    // off your own output is worse than no reading, because nothing on the
    // face would say where it came from.
    final tabs = [
      for (var input = 0; input < channels; input++)
        if (excluded & (1 << input) == 0)
          PillTab(value: input, label: l10n.inputName(inputs.names, input)),
    ];

    return KeyedSubtree(
      key: const Key('tuner_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HostTrayChromeBar(
            backKey: const Key('tuner_back'),
            title: l10n.trayTunerLabel,
            onBack: widget.onBack,
          ),
          if (tabs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(19, 12, 19, 0),
              child: PillTabs<int>(
                tabs: tabs,
                selected: tuner.input,
                onChanged: context.read<TunerCubit>().selectInput,
              ),
            ),
          Expanded(
            child: Center(
              child: channels == 0
                  ? _TunerMessage(text: l10n.tunerNoDevice)
                  : tabs.isEmpty
                  // A device IS open, so "no audio device" would be wrong, and
                  // "play a note" would be a promise nothing can keep: every
                  // capture on this rig is a loopback of our own output.
                  ? _TunerMessage(text: l10n.tunerNoTunableInput)
                  : tuner.hasReading
                  ? _TunerReadout(state: tuner)
                  : _TunerMessage(text: l10n.tunerListening),
            ),
          ),
        ],
      ),
    );
  }
}

/// The note, the needle and the readout — the whole face when there is
/// something to show.
class _TunerReadout extends StatelessWidget {
  const _TunerReadout({required this.state});

  final TunerState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final pitch = state.pitch!;

    return Column(
      key: const Key('tuner_readout'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // The mockup's fs67, at the tray's own weight.
        Text(
          pitch.note,
          key: const Key('tuner_note'),
          style: TextStyle(
            fontSize: 67,
            height: 1,
            fontWeight: FontWeight.w600,
            color: state.isStale ? surface.textSecondary : surface.textPrimary,
          ),
        ),
        const SizedBox(height: 24),
        _TunerNeedle(cents: pitch.cents, inTune: pitch.isInTune),
        const SizedBox(height: 20),
        Text(
          l10n.tunerCentsAndHz(
            _cents(pitch.cents),
            state.hz.toStringAsFixed(1),
          ),
          key: const Key('tuner_cents'),
          style: TextStyle(fontSize: 16, color: surface.textSecondary),
        ),
      ],
    );
  }

  /// Signed cents with a real minus (U+2212) and an explicit `+`, matching the
  /// mockup's own readout rather than what `toString` produces.
  static String _cents(double cents) {
    final rounded = cents.round();
    if (rounded == 0) return '0';
    return rounded > 0 ? '+$rounded' : '−${rounded.abs()}';
  }
}

/// The needle: a full-width track, a fixed centre tick, and an indicator that
/// slides with the error.
///
/// Full scale is ±50 cents — half a semitone, the point at which the reading
/// would name the neighbouring note instead. The mockup's indicator offset is
/// not a round fraction of its track, so the scale is chosen to be meaningful
/// rather than reverse-engineered from one drawn pixel; the geometry that
/// results goes back into the pen.
class _TunerNeedle extends StatelessWidget {
  const _TunerNeedle({required this.cents, required this.inTune});

  final double cents;
  final bool inTune;

  /// Cents at either end of the track.
  static const double fullScale = 50;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final clamped = cents.clamp(-fullScale, fullScale) / fullScale;

    return SizedBox(
      height: 22,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            alignment: Alignment.center,
            children: [
              // Track.
              Container(
                height: 10,
                decoration: BoxDecoration(
                  color: surface.control,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              // Centre tick — where in tune is.
              Container(width: 1, height: 22, color: surface.borderStrong),
              // The indicator.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 90),
                curve: Curves.easeOut,
                left: (width / 2) + (clamped * width / 2) - 2.5,
                child: Container(
                  key: const Key('tuner_needle'),
                  width: 5,
                  height: 17,
                  decoration: BoxDecoration(
                    color: inTune ? surface.success : surface.textPrimary,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The states the design does not draw: armed and silent, and no device.
class _TunerMessage extends StatelessWidget {
  const _TunerMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    key: const Key('tuner_message'),
    textAlign: TextAlign.center,
    style: TextStyle(fontSize: 16, color: context.surface.textSecondary),
  );
}
