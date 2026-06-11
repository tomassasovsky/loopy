/// Colours for the routing graphs. Two concepts are kept deliberately
/// separate:
///
/// * a **positional lane palette** — one hue per lane, cycled, so a lane's
///   node, cards, and wires read as one traceable colour ([laneColor]); and
/// * **send-role colours** — wet (effected) vs dry (clean) for the monitor
///   graph's two parallel sends ([kWetRouteColor] / [kDryRouteColor]).
///
/// They happen to share blue/amber at the low indices, but they answer
/// different questions ("which lane?" vs "which send?") and must not be
/// conflated.
library;

import 'package:flutter/material.dart';

/// The effected (wet) send colour — the signal that runs through the chain.
const Color kWetRouteColor = Color(0xFF3B82F6);

/// The clean (dry) send colour — the untouched parallel send.
const Color kDryRouteColor = Color(0xFFF59E0B);

/// Eight distinct hues, one per lane and cycled past the lane cap, so each
/// lane's node, cards, and wires share a single colour that can be traced
/// through a dense graph.
const List<Color> kLanePalette = [
  Color(0xFF3B82F6), // blue
  Color(0xFFF59E0B), // amber
  Color(0xFF2DD4BF), // teal
  Color(0xFFA78BFA), // violet
  Color(0xFFF472B6), // pink
  Color(0xFF34D399), // green
  Color(0xFFFB923C), // orange
  Color(0xFF38BDF8), // sky
];

/// The palette hue for [lane] (cycled past the palette length).
Color laneColor(int lane) => kLanePalette[lane % kLanePalette.length];
