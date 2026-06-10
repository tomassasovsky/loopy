part of 'audio_setup_view.dart';

/// The vertical step list shown in the left rail: numbered items with the
/// current one highlighted and completed ones checked.
class _StepList extends StatelessWidget {
  const _StepList({required this.steps, required this.current});

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 18),
            child: _StepListItem(
              index: i,
              label: steps[i],
              done: i < current,
              active: i == current,
            ),
          ),
      ],
    );
  }
}

class _StepListItem extends StatelessWidget {
  const _StepListItem({
    required this.index,
    required this.label,
    required this.done,
    required this.active,
  });

  final int index;
  final String label;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final labelColor = active ? _C.t1 : (done ? _C.t2 : _C.t3);
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? _C.accent : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(color: active ? _C.accent : _C.line),
          ),
          child: done
              ? const Icon(Icons.check, size: 14, color: _C.t2)
              : Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: active ? _C.onAccent : _C.t3,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: _num,
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: labelColor,
              fontSize: 14,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: _kicker.copyWith(color: _C.t2)),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: _C.line, height: 1)),
      ],
    );
  }
}

/// Lays children out as equal-width columns with consistent gaps.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < children.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == children.length - 1 ? 0 : 8),
              child: children[i],
            ),
          ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.optionKey,
    required this.headline,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  final String optionKey;
  final String headline;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key(optionKey),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? _C.accentSoft : _C.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _C.accent : _C.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(
              headline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? _C.accent : _C.t1,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFeatures: _num,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? _C.accent.withValues(alpha: 0.7) : _C.t3,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.toggleKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String toggleKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
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
                    color: _C.t1,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: _C.t2,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            key: Key(toggleKey),
            value: value,
            onChanged: onChanged,
            activeThumbColor: _C.onAccent,
            activeTrackColor: _C.accent,
            inactiveThumbColor: _C.t2,
            inactiveTrackColor: _C.cardHi,
            trackOutlineColor: const WidgetStatePropertyAll(_C.line),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.icon = Icons.info_outline, super.key});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: _C.t3),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: _C.t3, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('audioSetup_error_text'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x1AFF5468),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: _C.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: _C.danger, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Primary extends StatelessWidget {
  const _Primary({
    required this.label,
    required this.icon,
    required this.onTap,
    this.iconTrailing = false,
    this.stretch = false,
    this.danger = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool iconTrailing;
  final bool stretch;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final bg = danger ? _C.danger : _C.accent;
    final fg = danger ? Colors.white : _C.onAccent;
    final iconWidget = Icon(icon, size: 19, color: fg);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: stretch ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          child: Row(
            mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!iconTrailing) ...[iconWidget, const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (iconTrailing) ...[const SizedBox(width: 8), iconWidget],
            ],
          ),
        ),
      ),
    );
  }
}

class _Ghost extends StatelessWidget {
  const _Ghost({
    required this.label,
    required this.onTap,
    this.icon,
    this.stretch = false,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: stretch ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _C.line),
          ),
          child: Row(
            mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: _C.t2),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _C.t2,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: _C.accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _C.accent.withValues(alpha: 0.2 + 0.5 * t),
                blurRadius: 5 + 8 * t,
                spreadRadius: 0.5 + t,
              ),
            ],
          ),
        );
      },
    );
  }
}
