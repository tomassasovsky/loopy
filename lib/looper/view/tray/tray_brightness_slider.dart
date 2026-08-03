import 'package:flutter/material.dart';
import 'package:loopy/appliance/software_brightness.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';

/// The brightness control, Control-Center style: a tall bar, built by
/// rotating a plain [Slider] a quarter turn — `RotatedBox` rotates
/// hit-testing along with painting, so the drag gesture lands correctly
/// without any custom gesture math. [Slider] already brings its own tap,
/// drag, and keyboard handling, unlike the hand-rolled `SignalKnob`; only
/// its semantics need replacing (see [_TrayBrightnessSliderState] below).
/// Brightness is persisted and applied via `SettingsTrayCubit.setBrightness`.
class TrayBrightnessSlider extends StatefulWidget {
  /// Creates a [TrayBrightnessSlider].
  const TrayBrightnessSlider({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// Current brightness, `kMinDisplayBrightness..1`.
  final double value;

  /// Called with the new brightness on drag, tap, or an a11y adjust action.
  final ValueChanged<double> onChanged;

  @override
  State<TrayBrightnessSlider> createState() => _TrayBrightnessSliderState();
}

class _TrayBrightnessSliderState extends State<TrayBrightnessSlider> {
  /// The step announced by the accessibility increase/decrease actions —
  /// independent of [Slider]'s own *physical*-keyboard step, which is
  /// platform-dependent (`_adjustmentUnit` in the Flutter SDK's
  /// `slider.dart`: 10% on iOS/macOS, 5% elsewhere) and out of our control.
  static const double _step = 0.05;

  final _focusNode = FocusNode(debugLabel: 'settingsTray_brightness');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _increase() =>
      widget.onChanged(clampDisplayBrightness(widget.value + _step));

  void _decrease() =>
      widget.onChanged(clampDisplayBrightness(widget.value - _step));

  static String _percent(double value) => '${(value * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return RotatedBox(
      key: const Key('settingsTray_brightness'),
      // -90°: dragging up (screen-space) increases the slider's own
      // left-to-right value.
      quarterTurns: 3,
      // Slider sets its own semantics boundary — an ancestor label never
      // merges into it, always landing as a second, disjoint node — so its
      // semantics are excluded and replaced wholesale here with one node a
      // screen reader actually reads as "Brightness, 80%" rather than two
      // unconnected stops. A GestureDetector requests focus on tap-down
      // (Slider only does that as a side effect of its own recognizers
      // winning the gesture arena, which an outer detector can't rely on).
      child: Semantics(
        // `container: true` — otherwise this merges upward into whatever
        // ancestor Semantics happens to be in scope (the tray's own scrim
        // dismiss button included), instead of staying its own node.
        container: true,
        slider: true,
        label: l10n.trayBrightnessLabel,
        value: _percent(widget.value),
        increasedValue: _percent(
          clampDisplayBrightness(widget.value + _step),
        ),
        decreasedValue: _percent(
          clampDisplayBrightness(widget.value - _step),
        ),
        onIncrease: _increase,
        onDecrease: _decrease,
        child: ExcludeSemantics(
          // A `Listener` (not a `GestureDetector`) — Slider's own drag
          // recognizer resolves the gesture arena eagerly (on pointer-down,
          // for a responsive drag-to-set-value feel), rejecting a competing
          // `TapGestureRecognizer` before its `onTapDown` ever fires. A raw
          // pointer listener sits outside that arena entirely, so it always
          // sees the down event regardless of which recognizer wins it.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _focusNode.requestFocus(),
            // A translucent capsule behind the bar, matching the tiles'
            // frosted-card look — a bare `Slider` on its own reads as a
            // stray line floating over the panel, not a real control.
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surface.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 18,
                    activeTrackColor: surface.accent,
                    inactiveTrackColor: surface.accent.withValues(alpha: 0.12),
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 11,
                      elevation: 2,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    focusNode: _focusNode,
                    // Floor above 0 — software dim at 0 is a black screen.
                    min: kMinDisplayBrightness,
                    value: clampDisplayBrightness(widget.value),
                    onChanged: widget.onChanged,
                    label: _percent(widget.value),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
