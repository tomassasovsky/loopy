import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// Shared visual language for the Signal surface — the "instrument panel" look:
/// a monospace machine voice for every readout, glowing gate pills, mono
/// letter-spaced section headers, and keyboard chips. Centralised here so the
/// nodes, dock, and chrome stay cohesive (and so the aesthetic is tuned in one
/// place).

/// Below this width the three panes stack into one scrolling column (D8).
const double kSignalStackBreakpoint = 960;

/// The mix-knob ceiling: 2.0 linear gain ≈ +6 dB (matches the engine's
/// `LE_MAX_GAIN`), so a quiet take/input can be boosted, not only attenuated.
const double kSignalMaxGain = 2;

/// The slightly-lighter hairline (mockup `--line2`) for chip / pill / toggle
/// borders that sit one step brighter than the card outline.
const Color kSignalLine2 = Color(0xFF34343F);

/// The "machine readout" surface behind a recessed badge (mockup `#14141a`).
const Color kSignalInset = Color(0xFF14141A);

/// The surface of a Signal dropdown menu — a step above the cards so it reads
/// as a lifted panel rather than the flat Material default that blends in.
const Color kSignalMenu = Color(0xFF22222C);

/// The recessed "active-blue" accent — the snapshot/enabled signature used by
/// the track take's FX-snapshot badge and an enabled output gate (mockup
/// `.snap` / `.on`): a deep navy fill, a mid-blue hairline, and a pale-blue ink.
const Color kSignalSnapshotBg = Color(0xFF11233B);
const Color kSignalSnapshotLine = Color(0xFF2A5D9E);
const Color kSignalSnapshotInk = Color(0xFFBFE0FF);

/// Shared chrome for a Signal dropdown menu: a rounded, bordered, lifted card
/// matching the instrument panel. Pair with [kSignalMenu] for the colour.
RoundedRectangleBorder signalMenuShape() => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(10),
  side: const BorderSide(color: kSignalLine2),
);

/// The stable hue for output [output], sourced from the theme's lane palette so
/// every routing chip + output row wears one traceable colour (D5).
Color outputColor(SurfaceTheme s, int output) =>
    s.lanePalette[output % s.lanePalette.length];

/// A monospace text style (IBM Plex Mono) for numerics, ids, and machine
/// labels. [tracking] is letter-spacing in logical pixels.
TextStyle signalMono({
  required Color color,
  double size = 11,
  double tracking = 0,
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: SurfaceTheme.monoFont,
  color: color,
  fontSize: size,
  fontWeight: weight,
  letterSpacing: tracking,
  height: 1.1,
);

/// A soft neon glow around an accent element (used on the focused node ring,
/// the gate dot, and selected FX chips).
List<BoxShadow> signalGlow(
  Color color, {
  double blur = 16,
  double spread = -4,
}) => [
  BoxShadow(
    color: color.withValues(alpha: 0.55),
    blurRadius: blur,
    spreadRadius: spread,
  ),
];

/// The on/off **gate** pill — a rounded mono capsule with a glowing status dot,
/// reading `LIVE` (lit) or `OFF` (dim). This is the "is this input/output part
/// of the signal" affordance, named for assistive tech by its parent.
class SignalGatePill extends StatelessWidget {
  /// Creates a [SignalGatePill].
  const SignalGatePill({
    required this.label,
    required this.on,
    required this.color,
    super.key,
  });

  /// The pill caption (e.g. `LIVE` / `OFF`).
  final String label;

  /// Whether the gate is open (lit + glowing) or closed (greyed).
  final bool on;

  /// The lit accent colour.
  final Color color;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = on ? color : surface.textTertiary;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 9, 3),
      decoration: BoxDecoration(
        // mockup .gate: default bg #14141a; .gate.on: rc 14% over #14141a.
        color: on
            ? Color.alphaBlend(color.withValues(alpha: 0.14), kSignalInset)
            : kSignalInset,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: on ? color.withValues(alpha: 0.55) : surface.line,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tint,
              boxShadow: on ? signalGlow(color, blur: 8, spread: 0) : null,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            label.toUpperCase(),
            style: signalMono(
              color: on ? surface.textPrimary : surface.textTertiary,
              size: 9,
              tracking: 1.2,
              weight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
