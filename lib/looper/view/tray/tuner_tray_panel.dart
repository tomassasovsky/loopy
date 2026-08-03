import 'package:flutter/material.dart';
import 'package:loopy/appliance/host_page_chrome.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';

/// In-tray tuner face.
///
/// Placement, not implementation: the console redesign (#442, decision D6)
/// gives the tuner a rail destination rather than a full-screen takeover —
/// the tray is already near-fullscreen, so a takeover buys nothing — but a
/// real tuner needs pitch detection in the native engine and is tracked
/// separately. Until then this face says so plainly, which is the same
/// message the old `showComingSoonStub` dialog carried, in a place that does
/// not interrupt.
///
/// Placement here is provisional: its two siblings (`WifiTrayPanel`,
/// `BluetoothTrayPanel`) live in their own feature folders, and this face
/// should move to `lib/tuner/` once there is a tuner behind it.
class TunerTrayPanel extends StatelessWidget {
  /// Creates a [TunerTrayPanel].
  const TunerTrayPanel({required this.onBack, super.key});

  /// Returns to the tray home tiles (does not dismiss the tray).
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return KeyedSubtree(
      key: const Key('tuner_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HostTrayChromeBar(
            backKey: const Key('tuner_back'),
            title: l10n.trayTunerLabel,
            onBack: onBack,
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.graphic_eq,
                    size: 48,
                    color: surface.textTertiary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.trayComingSoonMessage(l10n.trayTunerLabel),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: surface.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
