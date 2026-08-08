/// Repository layer for the Segno looper: owns the audio engine and projects
/// its snapshots into looper domain models.
library;

// Engine wire-format constants + types that are not churn-prone shapes stay
// re-exported (documented D2 keepers): the effect-chain serializers and the
// effect/lane caps are stable native contracts, and `TrackState` is already
// surfaced through the `Track` / `LooperState` domain models. `ClickMode` /
// `GridDivision` / `TempoSource` are the same kind of keeper, now surfaced
// through `TransportState` (A4b). `LooperMode` joins them (B2a), also
// surfaced through `TransportState`. The audio-config cluster
// (AudioBackend/AudioDevice/EngineConfig/…) is wrapped in Part 2b.
export 'package:segno_engine/segno_engine.dart'
    show
        ClickMode,
        EngineResult,
        GridDivision,
        LooperMode,
        PluginScanProgress,
        TempoSource,
        TrackState,
        kMaxInputs,
        kMaxLanes,
        kTrackEffectMax,
        kTrackEffectParams;

// Domain audio-config models replace the engine's raw config/device types in
// the UI. The engine-typed boundary mappers stay package-internal (not shown).
export 'src/looper_repository.dart';
export 'src/models/audio_config.dart'
    show
        AudioBackend,
        AudioDevice,
        EngineConfig,
        LatencyState,
        LoopbackInfo,
        LoopbackKind;
export 'src/models/engine_status.dart';
// The stage-addressed FX model (FX v3 part 3a): the four-stage address + its
// canonical JSON (R19), the chain wire envelope (R13/R15), and the stable
// per-slot id minting helpers (A9).
export 'src/models/fx_address.dart' show FxAddress, FxStage;
export 'src/models/fx_chain_envelope.dart'
    show
        FxChainEnvelope,
        FxChainMeta,
        concatenateInheritedChains,
        decodeFxChain,
        encodeFxChain;
export 'src/models/fx_slot_ids.dart'
    show SlotIds, withFreshSlotIds, withMintedSlotIds;
export 'src/models/input_monitor.dart';
export 'src/models/lane.dart';
export 'src/models/looper_state.dart';
export 'src/models/plugin_descriptor.dart'
    show PluginDescriptor, PluginFormat, PluginParamInfo;
export 'src/models/session_rig.dart';
export 'src/models/track.dart';
// Domain effect models replace the engine's raw effect types in the UI. The
// engine-typed boundary mappers stay package-internal, with one exception:
// `trackEffectsToEngine`, for callers handing a live chain to another
// engine-facing repository (performance_repository's arm snapshot) instead of
// persisting it — see its doc.
export 'src/models/track_effect.dart'
    show
        BuiltInEffect,
        ParamReadout,
        PluginEffect,
        PluginRef,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType,
        decodeTrackEffects,
        encodeTrackEffects,
        fxChainFingerprint,
        trackEffectsToEngine;
export 'src/models/transport_state.dart';
export 'src/models/tuner_reading.dart';
// Plugin discovery: the async scan driver + its cache. PluginDescriptor itself
// is exported above with the other domain models.
export 'src/plugin_catalog.dart'
    show PluginCacheKey, PluginCatalog, PluginCatalogCache, PluginFileStat;

/// The iteration ceiling for the structural output gate's bootstrap reapply
/// scan, engine-aligned with `kMaxInputs` (`LE_MAX_INPUTS == 8`).
///
/// The output count is device-dependent and unknown at bootstrap, and the gate
/// is default-on (only explicitly-disabled outputs are persisted), so no exact
/// bound is needed for correctness. This is only how far the bootstrap reapply
/// scans the `output_enabled.$out` keys — matching how the monitor reapply
/// scans `[0, kMaxInputs)`. A stored off-state for an output beyond the current
/// device's channel count is ignored by the engine and never corrupts routing.
const int kMaxOutputs = 8;
