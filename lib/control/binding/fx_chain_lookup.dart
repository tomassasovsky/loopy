import 'package:looper_repository/looper_repository.dart';

/// The one stage→chain lookup every binding path shares.
///
/// Both resolvers (`FxBindingResolver` for `enabled` flips,
/// `ControlValueResolver` for value writes) and the label helpers ask the same
/// question — "what, if anything, is the chain at this address?" — and must
/// answer it identically. A
/// second copy of this table is how a new FX stage silently resolves in one
/// place and goes inert in another.
extension FxChainLookup on LooperRepository {
  /// The chain's entries at [address], or `null` when the rig has no chain
  /// there at all.
  ///
  /// An EMPTY chain and a missing one are different: a configured monitor with
  /// no effects still resolves (its chain flag is real and stompable), while a
  /// stage the rig never configured does not. The per-stage accessors below
  /// already draw that line — they return an empty list for a configured stage
  /// and nothing for an absent one.
  ///
  /// A Loop address with NO lane does not name a chain — every lane owns one,
  /// so there is nothing to pick between. Coercing the null to lane 0 would
  /// silently act on (or, in a label, describe) a chain the user never bound,
  /// which is the retarget A9 forbids; it resolves to nothing instead.
  List<TrackEffect>? chainEntriesAt(FxAddress address) {
    if (address.index < 0) return null;
    final lane = address.lane;
    return switch (address.stage) {
      FxStage.input =>
        allMonitors().containsKey(address.index)
            ? monitorEffects(address.index)
            : null,
      FxStage.loop =>
        lane != null && allLaneChains().containsKey((address.index, lane))
            ? laneEffects(address.index, lane)
            : null,
      FxStage.track =>
        allTrackChains().containsKey(address.index)
            ? trackEffects(address.index)
            : null,
      // There is exactly one Master insert and it always exists; a non-zero
      // index is a malformed address rather than a second one.
      FxStage.master => address.index == 0 ? masterEffects : null,
    };
  }
}
