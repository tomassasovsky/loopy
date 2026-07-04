import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:loopy/control/control_intents.dart';
import 'package:loopy/control/control_overlay.dart';
import 'package:loopy/looper/model/looper_mode.dart';

/// The business-logic front for the control overlay: widgets `watch` it for
/// mode / cursor / bank rebuilds and call its methods for control actions —
/// presentation never reaches past this layer.
///
/// Both directions go through the domain layer, so no cubit ever depends on
/// another cubit (bloc-to-bloc communication): state flows IN from the
/// [ControlOverlay] store (this cubit is a pure mirror of it — it stores
/// nothing of its own), and commands flow OUT through [ControlIntents], the
/// ONE interpreter shared verbatim with the pedal's footswitch decode, so
/// the surfaces cannot diverge in the command sequences they issue.
class ControlOverlayCubit extends Cubit<ControlOverlayState> {
  /// Creates a [ControlOverlayCubit] mirroring [overlay] and delegating
  /// actions to [intents].
  ControlOverlayCubit({
    required ControlOverlay overlay,
    required ControlIntents intents,
  }) : _overlay = overlay,
       _intents = intents,
       super(overlay.state) {
    _overlay.addListener(_onChange);
  }

  final ControlOverlay _overlay;
  final ControlIntents _intents;

  void _onChange(ControlOverlayState state) {
    if (!isClosed) emit(state);
  }

  // ---------------------------------------------------------------------------
  // Presentation-facing actions — thin delegations to the one interpreter.
  // New state arrives through the store mirror, never from these directly.
  // ---------------------------------------------------------------------------

  /// Toggles Record / Play mode.
  void toggleMode() => _intents.toggleMode();

  /// Sets and persists the boot-default mode, applying it now.
  void setDefaultMode(LooperMode mode) =>
      unawaited(_intents.setDefaultMode(mode));

  /// Moves the shared cursor to [channel] (reveals its bank).
  void selectTrack(int channel) => _intents.selectTrack(channel);

  /// Reveals [bank] without moving the cursor (the browse flow).
  void browseBank(int bank) => _intents.browseBank(bank);

  /// Toggles the visible bank, moving the cursor to the new bank's first
  /// track — the keyboard `B` / pedal BANK semantics.
  void toggleBankWithCursor() => _intents.toggleBankWithCursor();

  /// The whole-rig reset: every track cleared and re-armed, overlay home.
  void clearAll() => _intents.clearAll();

  @override
  Future<void> close() async {
    _overlay.removeListener(_onChange);
    return super.close();
  }
}
