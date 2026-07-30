import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Writes track [channel]'s Track-stage chain envelope (`{chainEnabled,
/// entries}`, R13/R15) to the settings store, read back by the boot restore.
///
/// ONE definition, shared by every surface that can flip a Track chain:
/// `LooperBloc` (the on-screen FX dock and the keyboard) and `ControlCubit`
/// (the pedal's FX-mode stomps). A cubit never calls a bloc, so the pedal path
/// cannot route its persistence through the bloc's handler — without this
/// helper the two paths would carry two copies of the envelope encoding and
/// could drift, leaving a stomped chain that resurrects on the next boot.
///
/// No-op when [settings] is null (the bloc's settings dependency is optional).
void persistTrackFxChain({
  required SettingsRepository? settings,
  required LooperRepository looper,
  required int channel,
}) {
  if (settings == null) return;
  unawaited(
    settings.saveTrackFxChain(
      channel,
      encodeFxChain(
        FxChainEnvelope(
          chainEnabled: looper.trackChainEnabled(channel),
          entries: looper.trackEffects(channel),
        ),
      ),
    ),
  );
}
