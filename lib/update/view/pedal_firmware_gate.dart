import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/pedal_firmware_cubit.dart';

/// Covers [child] while the pedal's firmware is being flashed.
///
/// The cover is the point. Programming leaves the pedal in its bootloader with
/// dead footswitches and a dark ring for the duration; a user left in the
/// looper reads that as broken hardware, not as an update in progress. So the
/// looper is not merely obscured, it is unreachable until the flash resolves.
///
/// Nothing is drawn while the answer is still being fetched, so the ordinary
/// case — desktop, or a console with nothing to flash — never flickers a screen
/// the user did not need to see.
class PedalFirmwareGate extends StatelessWidget {
  /// Creates a [PedalFirmwareGate] over [child].
  const PedalFirmwareGate({required this.child, super.key});

  /// The looper, shown once no flash is pending.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PedalFirmwareCubit, PedalFirmwareState>(
      builder: (context, state) {
        if (!state.blocksLooper) return child;
        return Stack(
          children: [
            child,
            const Positioned.fill(
              child: ModalBarrier(
                key: Key('pedal_firmware_gate_barrier'),
                dismissible: false,
                color: Colors.black87,
              ),
            ),
            // The gate wraps the looper from `home:`, so it sits ABOVE the
            // Scaffold and has no Material ancestor of its own — text fell
            // back to the debug style and the button had nothing to paint on.
            // Transparent so the barrier behind it still shows through.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: _GateBody(state: state),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GateBody extends StatelessWidget {
  const _GateBody({required this.state});

  final PedalFirmwareState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final failed = state.stage == PedalFirmwareStage.failed;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          key: const Key('pedal_firmware_gate'),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: surface.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: surface.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                failed
                    ? l10n.pedalFirmwareGateFailedTitle
                    : l10n.pedalFirmwareGateTitle,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                failed
                    ? l10n.pedalFirmwareGateFailedBody
                    : l10n.pedalFirmwareGateBody(state.version ?? ''),
                style: TextStyle(color: surface.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),
              if (failed)
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const Key('pedal_firmware_gate_continue'),
                    onPressed: context.read<PedalFirmwareCubit>().dismiss,
                    child: Text(l10n.pedalFirmwareGateContinue),
                  ),
                )
              else
                LinearProgressIndicator(
                  key: const Key('pedal_firmware_gate_progress'),
                  // Determinate from the first frame: the helper reports
                  // PROGRESS from 0, and a bar that sits still is more honest
                  // than a spinner about a flash that takes seconds, not
                  // milliseconds.
                  value: state.progress,
                  backgroundColor: surface.line,
                  color: surface.accent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
