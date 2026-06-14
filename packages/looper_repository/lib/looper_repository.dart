/// Repository layer for the Loopy looper: owns the audio engine and projects
/// its snapshots into looper domain models.
library;

export 'package:loopy_engine/loopy_engine.dart'
    show
        AudioBackend,
        AudioDevice,
        EngineConfig,
        EngineResult,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        ParamReadout,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType,
        TrackState,
        decodeTrackEffects,
        encodeTrackEffects,
        kMaxInputs,
        kMaxLanes,
        kTrackEffectMax,
        kTrackEffectParams;

export 'src/looper_repository.dart';
export 'src/models/engine_status.dart';
export 'src/models/input_monitor.dart';
export 'src/models/lane.dart';
export 'src/models/looper_state.dart';
export 'src/models/track.dart';
export 'src/models/transport_state.dart';
