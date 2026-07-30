import 'dart:convert';

import 'package:equatable/equatable.dart';

/// The four FX stages of the v3 signal path (#351), in signal order.
///
/// Every effects chain in the app lives at exactly one stage; an [FxAddress]
/// names one chain by stage + coordinates.
enum FxStage {
  /// A hardware input's live-monitor chain (pre-record, never recorded).
  input,

  /// A lane's record-route (loop playback) chain.
  loop,

  /// A track's stereo-bus chain, downstream of its lanes.
  track,

  /// The Master insert on the summed track mix, before gain/limiter.
  master;

  /// Maps a canonical wire [name] back to a stage, or `null` when unknown.
  static FxStage? fromName(String? name) {
    for (final stage in values) {
      if (stage.name == name) return stage;
    }
    return null;
  }
}

/// The address of one effects chain in the four-stage FX model (A9/R19):
/// `{stage, index, lane?}`.
///
/// Per-stage field meaning:
///
/// - [FxStage.input]: [index] is the hardware input channel; [lane] is unused
///   and must be null.
/// - [FxStage.loop]: [index] is the track channel; [lane] is the lane within
///   that track (required to name one chain, since every lane owns one).
/// - [FxStage.track]: [index] is the track channel; [lane] is unused (null).
/// - [FxStage.master]: there is exactly one Master insert — [index] is `0`
///   and [lane] is null.
///
/// ## Canonical JSON (the single declaration — R19)
///
/// [canonicalString] is THE serialization pedal bindings (part 6) and
/// expression mappings (part 7) persist and compare: a JSON object with the
/// fixed key order `stage`, `index`, `lane`, where `stage` is the enum name
/// and an absent [lane] is OMITTED (never null-valued). No whitespace beyond
/// `jsonEncode`'s none. Byte-stable: the same address always encodes to the
/// same string, so plain string equality == target identity, and the string
/// crosses the `controller_repository` / `pedal_repository` boundary without
/// those packages gaining a looper dependency.
///
/// Compatibility contract: fields are additive-only — a future revision may
/// add keys, and [FxAddress.fromJson] ignores keys it does not know, so an
/// older build can still decode a newer address. Existing keys never change
/// meaning or order.
class FxAddress extends Equatable {
  /// Creates an [FxAddress]. See the class doc for per-stage field meaning.
  const FxAddress({required this.stage, this.index = 0, this.lane});

  /// Rebuilds an [FxAddress] from its [toJson] map. Unknown keys are ignored
  /// (additive-only contract); an unknown or missing `stage` yields `null`.
  /// Wrong-TYPED fields never throw — a corrupt persisted binding string must
  /// decode to `null`, not a TypeError, since parts 6/7 feed this parser
  /// strings that crossed package boundaries and app restarts.
  static FxAddress? fromJson(Map<String, dynamic> json) {
    final rawStage = json['stage'];
    final stage = FxStage.fromName(rawStage is String ? rawStage : null);
    if (stage == null) return null;
    final index = json['index'];
    final lane = json['lane'];
    return FxAddress(
      stage: stage,
      index: index is num ? index.toInt() : 0,
      lane: lane is num ? lane.toInt() : null,
    );
  }

  /// Parses a [canonicalString] (or any JSON-object encoding of one) back to
  /// an address, or `null` when the string is not a decodable address.
  static FxAddress? tryParse(String encoded) {
    try {
      final raw = jsonDecode(encoded);
      if (raw is! Map<String, dynamic>) return null;
      return fromJson(raw);
    } on FormatException {
      return null;
    }
  }

  /// The stage this address names a chain on.
  final FxStage stage;

  /// The stage-scoped coordinate: input channel for [FxStage.input], track
  /// channel for [FxStage.loop] / [FxStage.track], `0` for [FxStage.master].
  final int index;

  /// The lane within track [index] — only meaningful for [FxStage.loop];
  /// null for every other stage.
  final int? lane;

  /// The canonical JSON map: fixed key order `stage`, `index`, `lane`; an
  /// absent [lane] is omitted, never null-valued.
  Map<String, dynamic> toJson() => {
    'stage': stage.name,
    'index': index,
    if (lane != null) 'lane': lane,
  };

  /// The byte-stable canonical serialization (see the class doc). Equal
  /// addresses always produce identical strings, so string equality is
  /// target identity for binding/mapping consumers.
  String canonicalString() => jsonEncode(toJson());

  /// Returns a copy with the given fields replaced. [lane] cannot be cleared
  /// back to null through this (construct a fresh address instead) — no
  /// current caller needs that, and an accidental clear would silently change
  /// which chain a loop-stage address names.
  FxAddress copyWith({FxStage? stage, int? index, int? lane}) => FxAddress(
    stage: stage ?? this.stage,
    index: index ?? this.index,
    lane: lane ?? this.lane,
  );

  @override
  List<Object?> get props => [stage, index, lane];
}
