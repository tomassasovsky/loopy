import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// Envelope-level chain metadata (R13): inherited provenance.
///
/// Owned by `looper_repository` — the engine never consumes it; it rides the
/// persisted envelope only.
class FxChainMeta extends Equatable {
  /// Creates an [FxChainMeta].
  const FxChainMeta({this.inheritedFrom = const []});

  /// Rebuilds an [FxChainMeta] from its [toJson] map; malformed entries are
  /// dropped. Unknown keys are ignored (additive-only contract).
  factory FxChainMeta.fromJson(Map<String, dynamic> json) {
    final raw = json['inheritedFrom'];
    return FxChainMeta(
      inheritedFrom: raw is List
          ? [
              for (final v in raw)
                if (v is num) v.toInt(),
            ]
          : const [],
    );
  }

  /// The hardware inputs this chain was inherited from at record time, in
  /// input order (A8). A single-input inherit is a one-element list; empty
  /// means the chain was never inherited (or part 4's detach cleared the
  /// marker).
  final List<int> inheritedFrom;

  /// Whether the chain carries an inheritance marker.
  bool get isInherited => inheritedFrom.isNotEmpty;

  /// A JSON-friendly map for persistence.
  Map<String, dynamic> toJson() => {'inheritedFrom': inheritedFrom};

  @override
  List<Object?> get props => [inheritedFrom];
}

/// The chain wire envelope `{chainEnabled, meta, entries}` (R13/R15) — the
/// ONE persisted string format for every stage's chain: settings keys, session
/// manifests (`SessionLaneChain.encoded` stays an opaque string; its content
/// is this), clear-restore snapshots, and the track/master stages.
///
/// Owned by `looper_repository` and WRAPPING `loopy_engine`'s entries codec:
/// [entries] persist exactly as the engine serializer writes them, and the
/// engine never consumes [chainEnabled] or [meta].
class FxChainEnvelope extends Equatable {
  /// Creates an [FxChainEnvelope].
  const FxChainEnvelope({
    this.chainEnabled = true,
    this.meta,
    this.entries = const [],
  });

  /// Whether the whole chain is engaged (R15). Disabled == the chain renders
  /// dry while keeping every per-entry flag intact.
  final bool chainEnabled;

  /// Inherited provenance, or null when the chain carries none.
  final FxChainMeta? meta;

  /// The chain entries, in processing order.
  final List<TrackEffect> entries;

  @override
  List<Object?> get props => [chainEnabled, meta, entries];
}

/// Encodes [envelope] to the persisted envelope string. [FxChainMeta] with no
/// content is omitted, so a never-inherited chain stays minimal.
String encodeFxChain(FxChainEnvelope envelope) {
  final meta = envelope.meta;
  return jsonEncode({
    'chainEnabled': envelope.chainEnabled,
    if (meta != null && meta.isInherited) 'meta': meta.toJson(),
    // Wraps the engine entries codec: encode through it, then embed its array
    // so the entry wire format has exactly one definition.
    'entries': jsonDecode(encodeTrackEffects(envelope.entries)),
  });
}

/// Decodes a chain envelope produced by [encodeFxChain] — or a LEGACY bare
/// entries array written by `encodeTrackEffects` before FX v3, which decodes
/// as `chainEnabled = true`, no meta ("migration defaults every level to
/// enabled", R15). Entries missing `enabled` default true; entries missing
/// `slotId` stay null for the repository write boundary to mint exactly once
/// (A9). Unknown envelope keys are ignored (additive-only contract); malformed
/// input yields an empty enabled envelope.
FxChainEnvelope decodeFxChain(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const FxChainEnvelope();
  final Object? raw;
  try {
    raw = jsonDecode(encoded);
  } on FormatException {
    return const FxChainEnvelope();
  }
  // Legacy bare array: exactly what decodeTrackEffects already accepts.
  if (raw is List) {
    return FxChainEnvelope(entries: decodeTrackEffects(encoded));
  }
  if (raw is! Map<String, dynamic>) return const FxChainEnvelope();
  final rawMeta = raw['meta'];
  final meta = rawMeta is Map<String, dynamic>
      ? FxChainMeta.fromJson(rawMeta)
      : null;
  // Wrong-TYPED fields must never throw (the malformed-input contract above):
  // this decoder runs uncaught on the boot path, so a corrupt persisted
  // string aborting decode would abort bootstrap. An `is`-check, not a cast.
  final rawChainEnabled = raw['chainEnabled'];
  return FxChainEnvelope(
    chainEnabled: rawChainEnabled is! bool || rawChainEnabled,
    meta: meta != null && meta.isInherited ? meta : null,
    entries: decodeTrackEffects(jsonEncode(raw['entries'])),
  );
}

/// Concatenates the chains a multi-input record mixes into one inherited
/// chain (A8, pinned semantics): entries concatenate **in input order** —
/// [sources] must already be ordered by input index — and the returned
/// [FxChainMeta.inheritedFrom] lists every source input in that same order.
///
/// Pure concatenation: the caller (the record-time snapshot path) still
/// captures plugin state and mints fresh slot ids on the result, exactly as
/// for a single-input inherit.
({List<TrackEffect> entries, FxChainMeta meta}) concatenateInheritedChains(
  List<(int input, List<TrackEffect> chain)> sources,
) => (
  entries: [for (final (_, chain) in sources) ...chain],
  meta: FxChainMeta(inheritedFrom: [for (final (input, _) in sources) input]),
);
