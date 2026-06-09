import 'package:flutter/material.dart';

/// Tabular figures keep numeric values vertically aligned in status tables.
const _setupNumerals = [FontFeature.tabularFigures()];

/// Shared palette for stepped setup surfaces (audio onboarding, settings).
class SetupSurfaceColors {
  static const bg = Color(0xFF08080A);
  static const surface = Color(0xFF0D0D11);
  static const card = Color(0xFF16161B);
  static const cardHi = Color(0xFF1C1C22);
  static const line = Color(0xFF272730);
  static const accent = Color(0xFF3B82F6);
  static const onAccent = Color(0xFFFFFFFF);
  static const t1 = Color(0xFFF3F4F7);
  static const t2 = Color(0xFF989AA4);
  static const t3 = Color(0xFF5B5D67);
}

const setupKicker = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.8,
  color: SetupSurfaceColors.t3,
);

const setupTitle = TextStyle(
  color: SetupSurfaceColors.t1,
  fontSize: 26,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.5,
);

const setupBody = TextStyle(
  color: SetupSurfaceColors.t2,
  fontSize: 14,
  height: 1.45,
);

/// A centered, bordered panel used by onboarding and settings flows.
class SetupSurfacePanel extends StatelessWidget {
  const SetupSurfacePanel({
    required this.child,
    this.maxWidth = 940,
    this.maxHeight = 640,
    super.key,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SetupSurfaceColors.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: SetupSurfaceColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: SetupSurfaceColors.line),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Section label with a trailing rule, matching the audio setup controls.
class SetupGroupLabel extends StatelessWidget {
  const SetupGroupLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: setupKicker.copyWith(color: SetupSurfaceColors.t2),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Divider(color: SetupSurfaceColors.line, height: 1),
        ),
      ],
    );
  }
}

/// Card-style toggle row used in onboarding and settings.
class SetupToggleRow extends StatelessWidget {
  const SetupToggleRow({
    required this.toggleKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final Key toggleKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SetupSurfaceColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: SetupSurfaceColors.t1,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: SetupSurfaceColors.t2,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            key: toggleKey,
            value: value,
            onChanged: onChanged,
            activeThumbColor: SetupSurfaceColors.onAccent,
            activeTrackColor: SetupSurfaceColors.accent,
            inactiveThumbColor: SetupSurfaceColors.t2,
            inactiveTrackColor: SetupSurfaceColors.cardHi,
            trackOutlineColor: const WidgetStatePropertyAll(
              SetupSurfaceColors.line,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable settings row with chevron, for navigation actions.
class SetupNavRow extends StatelessWidget {
  const SetupNavRow({
    required this.rowKey,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.icon = Icons.chevron_right,
    super.key,
  });

  final Key rowKey;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SetupSurfaceColors.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: rowKey,
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SetupSurfaceColors.line),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: SetupSurfaceColors.t1,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: SetupSurfaceColors.t2,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(icon, size: 20, color: SetupSurfaceColors.t3),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bordered card of label/value rows, used for read-only status (the audio
/// running panel and the in-settings audio status). Values use tabular figures
/// so numbers stay aligned.
class SetupInfoTable extends StatelessWidget {
  /// Creates a [SetupInfoTable] from `(label, value)` [rows].
  const SetupInfoTable({required this.rows, super.key});

  /// The label/value pairs, rendered one per row in order.
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: SetupSurfaceColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SetupSurfaceColors.line),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : const Border(
                        bottom: BorderSide(color: SetupSurfaceColors.line),
                      ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: SetupSurfaceColors.t2,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      rows[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: SetupSurfaceColors.t1,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: _setupNumerals,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Editable track-name row in the settings list.
class SetupTrackNameRow extends StatelessWidget {
  const SetupTrackNameRow({
    required this.rowKey,
    required this.channel,
    required this.name,
    required this.onTap,
    super.key,
  });

  final Key rowKey;
  final int channel;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SetupSurfaceColors.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: rowKey,
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SetupSurfaceColors.line),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: SetupSurfaceColors.cardHi,
                  shape: BoxShape.circle,
                  border: Border.all(color: SetupSurfaceColors.line),
                ),
                child: Text(
                  '${channel + 1}',
                  style: const TextStyle(
                    color: SetupSurfaceColors.t2,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SetupSurfaceColors.t1,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const Icon(
                Icons.edit_outlined,
                size: 16,
                color: SetupSurfaceColors.t3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
