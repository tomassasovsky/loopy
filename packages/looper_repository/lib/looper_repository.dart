/// Repository layer for the Loopy looper: owns the audio engine and projects
/// its snapshots into looper domain models.
library;

// Engine wire-format constants + types that are not churn-prone shapes stay
// re-exported (documented D2 keepers): the effect-chain serializers and the
// effect/lane caps are stable native contracts, and `TrackState` is already
// surfaced through the `Track` / `LooperState` domain models. The audio-config
// cluster (AudioBackend/AudioDevice/EngineConfig/…) is wrapped in Part 2b.
export 'package:loopy_engine/loopy_engine.dart'
    show
        EngineResult,
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
export 'src/models/input_monitor.dart';
export 'src/models/lane.dart';
export 'src/models/looper_state.dart';
export 'src/models/track.dart';
// Domain effect models replace the engine's raw effect types in the UI. The
// engine-typed boundary mappers stay package-internal (not shown here).
export 'src/models/track_effect.dart'
    show
        ParamReadout,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType,
        decodeTrackEffects,
        encodeTrackEffects;
export 'src/models/transport_state.dart';
