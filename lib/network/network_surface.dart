/// The Network domain's shared row/card vocabulary, drawn to the console
/// mockups' `NETWORK / *` screens.
///
/// WiFi and Bluetooth are the same surface with different nouns — a card of
/// 70px rows, each `title / subtitle` on the left and `value ›` on the right,
/// one of which can open to reveal its actions. Both faces build from these
/// pieces rather than each drawing its own, so the two tabs of one domain
/// cannot drift apart the way the two former panels had.
library;

import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Row height from the mockups (`row-h`). Big enough to hit while standing
/// over a floor console.
const double kNetworkRowHeight = 70;

/// Card corner radius for the Network faces.
const double _cardRadius = 12;

/// A card wrapping a group of [NetworkRow]s.
///
/// The 1px inset is the mockups' own: rows paint their hairline edge-to-edge,
/// and the inset keeps that hairline inside the rounded corner instead of
/// cutting across it.
class NetworkCard extends StatelessWidget {
  /// Creates a [NetworkCard].
  const NetworkCard({required this.children, this.bordered = false, super.key});

  /// The rows.
  final List<Widget> children;

  /// Whether to draw the outer border. The mockups border the Bluetooth
  /// visibility card and leave the device/network list unbordered.
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: bordered ? Border.all(color: surface.line) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_cardRadius - 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// One row of a [NetworkCard]: `title / subtitle` with a right-hand value and
/// a disclosure marker.
///
/// The marker is part of the row rather than a per-item decision — the
/// mockups reserve the gutter for every row in a group so the titles of rows
/// that have no chevron still line up with those that do.
class NetworkRow extends StatelessWidget {
  /// Creates a [NetworkRow].
  const NetworkRow({
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailing,
    this.expanded = false,
    this.showDisclosure = true,
    this.divider = true,
    super.key,
  });

  /// Primary label — an SSID, a device name, or a setting.
  final String title;

  /// Secondary line: the address, the signal, why it cannot be joined.
  final String? subtitle;

  /// Right-hand status word ("connected", "saved", "open").
  final String? value;

  /// Tapping opens the row. Null makes it inert (but still readable).
  final VoidCallback? onTap;

  /// Replaces the value + disclosure pair — used by the switch rows.
  final Widget? trailing;

  /// Whether this row is the open one, which turns the marker downwards.
  final bool expanded;

  /// Whether to reserve the disclosure gutter at all.
  final bool showDisclosure;

  /// Whether to paint the bottom hairline. False on a group's last row.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final line = subtitle;
    final status = value;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 15),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 17,
                    // Tight leading, from the mockups: title + subtitle have
                    // to clear 41px between the row's 14/15 padding, which
                    // Roboto's default 1.4 line height does not.
                    height: 1.2,
                  ),
                ),
                if (line != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: trailing,
            )
          else ...[
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(
                  status,
                  style: TextStyle(color: surface.textSecondary, fontSize: 14),
                ),
              ),
            if (showDisclosure)
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: NetworkDisclosure(expanded: expanded),
              ),
          ],
        ],
      ),
    );

    final row = SizedBox(
      height: kNetworkRowHeight,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );

    if (!divider) return row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.borderHairline)),
      ),
      child: row,
    );
  }
}

/// The row disclosure marker: a small solid triangle, pointing right while the
/// row is closed and down while it is open.
class NetworkDisclosure extends StatelessWidget {
  /// Creates a [NetworkDisclosure].
  const NetworkDisclosure({required this.expanded, super.key});

  /// Whether the row it belongs to is open.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      duration: const Duration(milliseconds: 160),
      turns: expanded ? 0.25 : 0,
      child: Icon(
        Icons.arrow_right,
        size: 18,
        color: context.surface.textMuted,
      ),
    );
  }
}

/// An opened row: the row itself over a right-aligned strip of its actions,
/// the pair tinted and lifted out of the list as one card.
class NetworkExpandedRow extends StatelessWidget {
  /// Creates a [NetworkExpandedRow].
  const NetworkExpandedRow({
    required this.row,
    required this.actions,
    super.key,
  });

  /// The row, built with `expanded: true`.
  final Widget row;

  /// Action chips, in reading order.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.control,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: surface.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final action in actions) ...[
                  if (action != actions.first) const SizedBox(width: 10),
                  action,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A pill button inside an opened row — Disconnect, Forget, Connect.
class NetworkActionChip extends StatelessWidget {
  /// Creates a [NetworkActionChip].
  const NetworkActionChip({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  /// Button text.
  final String label;

  /// Leading glyph.
  final IconData icon;

  /// Null disables the chip while the radio is busy.
  final VoidCallback? onPressed;

  /// Draws the chip in the record red — used by Forget, which deletes
  /// credentials.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = destructive ? surface.rec : surface.textSecondary;
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: surface.cardHigh,
        shape: StadiumBorder(
          side: BorderSide(color: destructive ? surface.recLine : surface.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: tint),
                const SizedBox(width: 10),
                Text(label, style: TextStyle(color: tint, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The face's title row: the radio's name, an optional live status beside it,
/// and the rescan + power controls.
///
/// Power lives here rather than in the list because it governs whether there
/// is a list at all — switched off, this row is the entire face.
class NetworkFaceHeader extends StatelessWidget {
  /// Creates a [NetworkFaceHeader].
  const NetworkFaceHeader({
    required this.title,
    required this.powered,
    required this.onPoweredChanged,
    this.status,
    this.onRescan,
    this.scanning = false,
    this.rescanKey,
    this.powerKey,
    super.key,
  });

  /// "WiFi" / "Bluetooth".
  final String title;

  /// Live status beside the title ("joining Studio 5G", "could not join …").
  final String? status;

  /// Radio state.
  final bool powered;

  /// Null while a power change is in flight.
  final ValueChanged<bool>? onPoweredChanged;

  /// Null hides the rescan button entirely — as the mockups do while the
  /// radio is off.
  final VoidCallback? onRescan;

  /// Spins the rescan glyph.
  final bool scanning;

  /// Key for the rescan button.
  final Key? rescanKey;

  /// Key for the power switch.
  final Key? powerKey;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final line = status;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (line != null) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: surface.textMuted, fontSize: 14),
              ),
            ),
          ],
          const Spacer(),
          if (onRescan != null) ...[
            _RescanButton(
              key: rescanKey,
              onPressed: onRescan,
              scanning: scanning,
            ),
            const SizedBox(width: 10),
          ],
          NetworkSwitch(
            key: powerKey,
            value: powered,
            onChanged: onPoweredChanged,
          ),
        ],
      ),
    );
  }
}

class _RescanButton extends StatelessWidget {
  const _RescanButton({
    required this.onPressed,
    required this.scanning,
    super.key,
  });

  final VoidCallback? onPressed;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Tooltip(
      message: l10n.networkRescanTooltip,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: surface.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: scanning ? null : onPressed,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Center(
              child: scanning
                  ? SizedBox(
                      width: 19,
                      height: 19,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: surface.textSecondary,
                      ),
                    )
                  : Icon(
                      Icons.refresh,
                      size: 19,
                      color: surface.textSecondary,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The console's switch: a 53x31 pill with a 25px knob.
///
/// Hand-drawn rather than Material's `Switch`, which carries its own 40x24
/// geometry, ripple and thumb elevation — none of which the mockups have, and
/// all of which read as borrowed once the switch sits in a list row.
class NetworkSwitch extends StatelessWidget {
  /// Creates a [NetworkSwitch].
  const NetworkSwitch({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  /// On/off.
  final bool value;

  /// Null disables the switch (busy, or unsupported).
  final ValueChanged<bool>? onChanged;

  /// Accessible name, since the switch carries no visible label of its own.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: GestureDetector(
          onTap: enabled ? () => onChanged!(!value) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: 53,
            height: 31,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: value ? surface.accent : surface.control,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: value ? surface.accent : surface.line),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 25,
                height: 25,
                decoration: BoxDecoration(
                  color: value ? surface.onAccent : surface.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The banner that rides at the top of the list while something is in flight
/// or has just failed: a state dot, the message, and the one action that
/// answers it.
class NetworkBanner extends StatelessWidget {
  /// Creates a [NetworkBanner].
  const NetworkBanner({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.failed = false,
    this.actionKey,
    super.key,
  });

  /// What is happening, in a sentence.
  final String message;

  /// The action's label — Cancel while in flight, Try again after a failure.
  final String actionLabel;

  /// Runs the action.
  final VoidCallback onAction;

  /// Colours the dot red rather than amber.
  final bool failed;

  /// Key for the action button.
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(color: surface.background),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 14, 20, 14),
        child: Row(
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: failed ? surface.rec : surface.warning,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: surface.textSecondary, fontSize: 16),
              ),
            ),
            const SizedBox(width: 14),
            NetworkSmallButton(
              key: actionKey,
              label: actionLabel,
              onPressed: onAction,
            ),
          ],
        ),
      ),
    );
  }
}

/// A small bordered button — the banner's Cancel / Try again, and the join
/// sheet's Cancel.
class NetworkSmallButton extends StatelessWidget {
  /// Creates a [NetworkSmallButton].
  const NetworkSmallButton({
    required this.label,
    required this.onPressed,
    this.large = false,
    super.key,
  });

  /// Button text.
  final String label;

  /// Runs the action.
  final VoidCallback? onPressed;

  /// The sheet's slightly larger form (40px tall, 15px label).
  final bool large;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: surface.cardHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: surface.borderStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: large ? 10 : 7,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: large ? 15 : 14,
            ),
          ),
        ),
      ),
    );
  }
}

/// The face when there is nothing to list: a bordered, empty card carrying one
/// line of explanation.
class NetworkEmptyCard extends StatelessWidget {
  /// Creates a [NetworkEmptyCard].
  const NetworkEmptyCard({required this.message, super.key});

  /// Why the list is empty.
  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: surface.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: surface.textSecondary, fontSize: 16),
          ),
        ),
      ),
    );
  }
}

/// Confirmation for an action that throws away a credential — forgetting a
/// network's passphrase, or a device's pairing.
///
/// Returns true when the destructive button is chosen. Disconnect has no
/// confirm of its own: it is undone by tapping the row again, while this is
/// not.
Future<bool> showNetworkForgetDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  Key? confirmKey,
}) async {
  final surface = context.surface;
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: surface.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(17),
        side: BorderSide(color: surface.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 528),
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                body,
                style: TextStyle(color: surface.textSecondary, fontSize: 16),
              ),
              const SizedBox(height: 19),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  NetworkSmallButton(
                    label: l10n.networkKeepItAction,
                    large: true,
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                  ),
                  const SizedBox(width: 10),
                  _DestructiveButton(
                    key: confirmKey,
                    label: confirmLabel,
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return confirmed ?? false;
}

class _DestructiveButton extends StatelessWidget {
  const _DestructiveButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: surface.rec,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: surface.onAccent,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
