import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files under `lib/` that may still name a colour directly, and why.
///
/// This is the record of every surface the design-system reconciliation
/// (#499) deliberately did **not** take over. Adding an entry is a design
/// decision, not a way to silence the test — each one needs a reason that
/// survives being read out loud in review.
const _allowed = <String, String>{
  // Gate decision on #499: virtual hardware. The plate's LEDs, silkscreen and
  // proportions mirror the physical pedal, so restyling it would desync the
  // simulator from the thing it simulates.
  'lib/pedal/view/pedal_plate.dart': 'pedal faceplate — hardware replica',

  // Gate decision on #499: the prototype is a 1920x1080 appliance view with no
  // title bar, so there is no design to adopt here — only one to invent.
  'lib/window/window_chrome.dart': 'desktop window chrome — no DS counterpart',

  // Drop shadows. The design system has no shadow tokens at all; these are not
  // palette drift, they are a gap on the DS side.
  'lib/app/app_toasts.dart': 'drop shadow — DS defines no shadow tokens',
  'lib/looper/view/signal_graph/signal_fx_rack.dart':
      'drag shadow — DS defines no shadow tokens',

  // The DS scrim (`bg-scrim`, ~42% alpha) is tuned for tray/overlay dimming.
  // This barrier blocks the whole app on incompatible firmware and needs to
  // read as a hard stop, which 42% does not carry. A heavier "modal scrim"
  // tier is a real DS gap.
  'lib/update/view/pedal_firmware_gate.dart':
      'blocking modal barrier — DS scrim is too light for a hard stop',

  // Runs in the second window, a separate engine that may have no theme
  // registered, so its theme lookups are null-guarded with literal fallbacks.
  // The playhead is deliberately white and carries its own gutter (3b).
  'lib/visualizer/widgets/waveform_view.dart':
      'themeless-context fallbacks + the white playhead',

  // An OS window option set before runApp, so it cannot read a theme.
  'lib/visualizer/waveform_window.dart': 'pre-runApp OS window background',
};

/// Colour literals that carry no palette meaning.
final _harmless = RegExp(r'Colors\.transparent');

void main() {
  test('the view layer resolves colour from the theme, not from literals', () {
    // #499 stage 3c. The reskin's whole premise is that colour lives in
    // SurfaceTheme/LooperTheme and nowhere else — a hex in a widget is
    // invisible to a palette migration and to the high-contrast variant, so
    // it silently rots. This walks `lib/` and fails on any new one.
    final offenders = <String>[];
    final literal = RegExp(r'Color\(0x|Colors\.[a-zA-Z]');

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The theme package is where colour is *supposed* to be spelled out.
      if (entity.path.startsWith('lib/theme/')) continue;
      if (_allowed.containsKey(entity.path)) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!literal.hasMatch(line)) continue;
        if (_harmless.hasMatch(line) && !RegExp(r'Color\(0x').hasMatch(line)) {
          continue;
        }
        offenders.add('${entity.path}:${i + 1}  ${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Hardcoded colour in the view layer. Resolve it from '
          'context.surface / LooperTheme, or add the file to _allowed in this '
          'test with the design reason it is exempt.\n${offenders.join('\n')}',
    );
  });

  test('the allowlist does not outlive the files it exempts', () {
    // An exemption for a file that no longer exists is a stale claim about the
    // codebase, and it would silently cover a *new* file at the same path.
    final missing = _allowed.keys.where((p) => !File(p).existsSync()).toList();
    expect(
      missing,
      isEmpty,
      reason: 'allowlisted files no longer exist: $missing',
    );
  });

  test('every allowlisted file actually still names a colour', () {
    // The inverse: once a file is cleaned up, its exemption should go with it,
    // or the allowlist slowly becomes a list of places nobody checks.
    final literal = RegExp(r'Color\(0x|Colors\.[a-zA-Z]');
    final clean = <String>[];
    for (final path in _allowed.keys) {
      final body = File(path).readAsStringSync();
      final hasReal = body
          .split('\n')
          .any((l) => literal.hasMatch(l) && !_harmless.hasMatch(l));
      if (!hasReal) clean.add(path);
    }
    expect(
      clean,
      isEmpty,
      reason:
          'these files no longer need their exemption — drop them from '
          '_allowed: $clean',
    );
  });
}
