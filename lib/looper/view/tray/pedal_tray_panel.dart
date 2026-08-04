import 'package:flutter/material.dart';
import 'package:segno/appliance/host_page_chrome.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/pedal/view/pedal_assignment_page.dart';

/// In-tray pedal-assignment face.
///
/// The surface that triggered the console redesign: remapping a footswitch
/// used to mean Settings -> Audio -> Pedal -> a button, three levels deep on a
/// device with no keyboard (#440). It is now one rail destination away from
/// the stage.
///
/// Renders the same [PedalAssignmentView] the full-screen route does. The
/// route is kept deliberately, and NOT because the tray is console-only — it
/// is mounted on every platform. It stays because Settings -> Audio -> Pedal
/// is where you already are when configuring the pedal, and losing the
/// assignment button from that context would trade one discoverability
/// problem for another. Two mounts, one widget: there is no second
/// implementation to drift.
class PedalTrayPanel extends StatelessWidget {
  /// Creates a [PedalTrayPanel].
  const PedalTrayPanel({required this.onBack, super.key});

  /// Returns to the tray home tiles (does not dismiss the tray).
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('pedal_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HostTrayChromeBar(
            backKey: const Key('pedal_back'),
            title: context.l10n.pedalAssignTitle,
            onBack: onBack,
          ),
          const Expanded(child: PedalAssignmentView()),
        ],
      ),
    );
  }
}
