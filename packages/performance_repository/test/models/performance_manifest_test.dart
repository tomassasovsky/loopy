import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:performance_repository/performance_repository.dart';

void main() {
  group('PerformanceLaneSnapshot', () {
    test('round-trips a settled lane through JSON', () {
      final lane = PerformanceLaneSnapshot(
        lane: 1,
        lengthFrames: 480,
        deferred: false,
        pcmFile: 'loops/track0-lane1.wav',
        effects: [BuiltInEffect(type: TrackEffectType.reverb)],
      );
      final decoded = PerformanceLaneSnapshot.fromJson(lane.toJson());
      expect(decoded.lane, 1);
      expect(decoded.lengthFrames, 480);
      expect(decoded.deferred, isFalse);
      expect(decoded.pcmFile, 'loops/track0-lane1.wav');
      expect(decoded.effects.single.typeCode, TrackEffectType.reverb.code);
    });

    test('round-trips a deferred lane (no pcmFile, no effects key)', () {
      const lane = PerformanceLaneSnapshot(
        lane: 0,
        lengthFrames: 0,
        deferred: true,
      );
      final json = lane.toJson();
      expect(json.containsKey('pcmRef'), isFalse);
      expect(json.containsKey('effects'), isFalse);
      final decoded = PerformanceLaneSnapshot.fromJson(json);
      expect(decoded.deferred, isTrue);
      expect(decoded.pcmFile, isNull);
      expect(decoded.effects, isEmpty);
    });
  });

  group('PerformanceTrackSnapshot', () {
    test('round-trips through JSON', () {
      const track = PerformanceTrackSnapshot(
        channel: 2,
        state: TrackState.playing,
        volume: 0.8,
        muted: true,
        multiple: 2,
        lanes: [
          PerformanceLaneSnapshot(lane: 0, lengthFrames: 240, deferred: false),
        ],
      );
      final decoded = PerformanceTrackSnapshot.fromJson(track.toJson());
      expect(decoded.channel, 2);
      expect(decoded.state, TrackState.playing);
      expect(decoded.volume, 0.8);
      expect(decoded.muted, isTrue);
      expect(decoded.multiple, 2);
      expect(decoded.lanes, hasLength(1));
    });
  });

  group('PerformanceArmSnapshot', () {
    test('round-trips through JSON, including monitors', () {
      const snapshot = PerformanceArmSnapshot(
        clockFrame: 100,
        masterLengthFrames: 48000,
        masterGain: 0.9,
        limiterEnabled: true,
        limiterCeiling: 0.95,
        latencyOffsetFrames: 64,
        tracks: [
          PerformanceTrackSnapshot(
            channel: 0,
            state: TrackState.playing,
            volume: 1,
            muted: false,
            multiple: 1,
          ),
        ],
        monitors: [
          {
            'input': 0,
            'enabled': true,
            'outputMask': 3,
            'volume': 1.0,
            'muted': false,
            'effects': <Map<String, dynamic>>[],
          },
        ],
      );
      final decoded = PerformanceArmSnapshot.fromJson(snapshot.toJson());
      expect(decoded.clockFrame, 100);
      expect(decoded.masterLengthFrames, 48000);
      expect(decoded.masterGain, 0.9);
      expect(decoded.limiterEnabled, isTrue);
      expect(decoded.limiterCeiling, 0.95);
      expect(decoded.latencyOffsetFrames, 64);
      expect(decoded.tracks, hasLength(1));
      expect(decoded.monitors, hasLength(1));
      expect(decoded.monitors.single['input'], 0);
      // A snapshot this code writes always carries the FX-stage marker, even
      // with no bus FX to record (R20).
      expect(
        decoded.fxStagesVersion,
        PerformanceArmSnapshot.currentFxStagesVersion,
      );
      expect(decoded.trackChains, isEmpty);
      expect(decoded.masterEffects, isEmpty);
      expect(decoded.masterChainEnabled, isTrue);
    });

    test(
      'round-trips the BUS stages with disabled entries and disabled chain '
      'flags (R20/R3)',
      () {
        final snapshot = PerformanceArmSnapshot(
          clockFrame: 0,
          masterLengthFrames: 480,
          masterGain: 1,
          limiterEnabled: false,
          limiterCeiling: 0.99,
          latencyOffsetFrames: 0,
          tracks: [
            PerformanceTrackSnapshot(
              channel: 0,
              state: TrackState.playing,
              volume: 1,
              muted: false,
              multiple: 1,
              lanes: [
                PerformanceLaneSnapshot(
                  lane: 0,
                  lengthFrames: 480,
                  deferred: false,
                  // A chain-disabled lane with an individually-disabled entry:
                  // both bits must survive so a replay seeds bypass state.
                  chainEnabled: false,
                  effects: [
                    BuiltInEffect(
                      type: TrackEffectType.delay,
                      enabled: false,
                      slotId: 'ab-1',
                    ),
                  ],
                ),
              ],
            ),
          ],
          trackChains: [
            PerformanceTrackChain(
              channel: 0,
              chainEnabled: false,
              effects: [
                BuiltInEffect(type: TrackEffectType.reverb, slotId: 'ab-2'),
              ],
            ),
            const PerformanceTrackChain(channel: 1),
          ],
          masterEffects: [
            BuiltInEffect(type: TrackEffectType.filter, enabled: false),
          ],
          masterChainEnabled: false,
        );

        final decoded = PerformanceArmSnapshot.fromJson(snapshot.toJson());

        final lane = decoded.tracks.single.lanes.single;
        expect(lane.chainEnabled, isFalse);
        final laneFx = lane.effects.single as BuiltInEffect;
        expect(laneFx.enabled, isFalse);
        // Slot ids ride the entries, so a replay can address the same slot.
        expect(laneFx.slotId, 'ab-1');
        expect(decoded.trackChains, hasLength(2));
        expect(decoded.trackChains[0].channel, 0);
        expect(decoded.trackChains[0].chainEnabled, isFalse);
        final busFx = decoded.trackChains[0].effects.single as BuiltInEffect;
        expect(busFx.typeCode, TrackEffectType.reverb.code);
        expect(busFx.slotId, 'ab-2');
        // A track that is only in the list because it exists reads as dry +
        // engaged.
        expect(decoded.trackChains[1].effects, isEmpty);
        expect(decoded.trackChains[1].chainEnabled, isTrue);
        expect(
          (decoded.masterEffects.single as BuiltInEffect).enabled,
          isFalse,
        );
        expect(decoded.masterChainEnabled, isFalse);
      },
    );

    test(
      'a LEGACY arm snapshot (no fxStagesVersion marker) still parses, with '
      'the bus stages empty and every chain enabled (R20)',
      () {
        final legacy = <String, dynamic>{
          'clockFrame': 10,
          'masterLenFrames': 480,
          'masterGain': 1.0,
          'limiterOn': false,
          'limiterCeiling': 0.99,
          'latencyOffsetFrames': 0,
          'tracks': [
            {
              'channel': 0,
              'state': 'playing',
              'volume': 1.0,
              'muted': false,
              'multiple': 1,
              'lanes': [
                {
                  'lane': 0,
                  'lenFrames': 480,
                  'deferred': false,
                  'pcmRef': 'loops/track0-lane0.wav',
                  'effects': [
                    {'type': TrackEffectType.reverb.code},
                  ],
                },
              ],
            },
          ],
          'monitors': [
            {
              'input': 0,
              'enabled': true,
              'outputMask': 3,
              'volume': 1.0,
              'muted': false,
              'effects': <Map<String, dynamic>>[],
            },
          ],
        };

        final decoded = PerformanceArmSnapshot.fromJson(legacy);

        expect(
          decoded.fxStagesVersion,
          PerformanceArmSnapshot.legacyFxStagesVersion,
        );
        expect(decoded.trackChains, isEmpty);
        expect(decoded.masterEffects, isEmpty);
        expect(decoded.masterChainEnabled, isTrue);
        // Everything the legacy schema DID describe is intact, defaulted to
        // audible — the pre-FX-v3 world had no other possibility.
        final lane = decoded.tracks.single.lanes.single;
        expect(lane.chainEnabled, isTrue);
        final laneFx = lane.effects.single as BuiltInEffect;
        expect(laneFx.enabled, isTrue);
        expect(laneFx.slotId, isNull);
      },
    );

    test(
      'omits the bus fields and every engaged flag when at their defaults',
      () {
        const snapshot = PerformanceArmSnapshot(
          clockFrame: 0,
          masterLengthFrames: 0,
          masterGain: 1,
          limiterEnabled: false,
          limiterCeiling: 0.99,
          latencyOffsetFrames: 0,
        );

        final json = snapshot.toJson();

        expect(json.containsKey('trackChains'), isFalse);
        expect(json.containsKey('masterEffects'), isFalse);
        expect(json.containsKey('masterChainEnabled'), isFalse);
        // …but the marker itself is always written, or a current snapshot
        // with no bus FX would be indistinguishable from a legacy one.
        expect(
          json['fxStagesVersion'],
          PerformanceArmSnapshot.currentFxStagesVersion,
        );
      },
    );
  });

  group('PerformanceTrackChain', () {
    test('round-trips through JSON, omitting the engaged flag', () {
      final chain = PerformanceTrackChain(
        channel: 3,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );

      final json = chain.toJson();
      expect(json.containsKey('chainEnabled'), isFalse);

      final decoded = PerformanceTrackChain.fromJson(json);
      expect(decoded.channel, 3);
      expect(decoded.chainEnabled, isTrue);
      expect(decoded.effects.single.typeCode, TrackEffectType.drive.code);
    });
  });

  group('PerformanceDisarmSnapshot', () {
    test('round-trips through JSON', () {
      const snapshot = PerformanceDisarmSnapshot(
        tracks: [
          PerformanceTrackSnapshot(
            channel: 3,
            state: TrackState.stopped,
            volume: 1,
            muted: false,
            multiple: 1,
          ),
        ],
      );
      final decoded = PerformanceDisarmSnapshot.fromJson(snapshot.toJson());
      expect(decoded.tracks.single.channel, 3);
    });
  });

  group('PerformanceLayerEntry', () {
    test('parses a part-5 native layer-manifest entry', () {
      final entry = PerformanceLayerEntry.fromJson(const {
        'channel': 1,
        'slot': 4,
        'generation': 2,
        'frame': 4800,
        'frame_count': 480,
        'lane_count': 1,
        'filename': 'layer-1-4800-4.pcm',
      });
      expect(entry.channel, 1);
      expect(entry.slot, 4);
      expect(entry.generation, 2);
      expect(entry.frame, 4800);
      expect(entry.frameCount, 480);
      expect(entry.laneCount, 1);
      expect(entry.filename, 'layer-1-4800-4.pcm');
    });
  });

  group('PerformanceManifest', () {
    test('preserves native fields verbatim while adding its own', () {
      final native = <String, dynamic>{
        'sample_rate': 48000,
        'capture_frames': 96000,
        'overrun_count': 2,
        'overrun_gaps': [
          {'frame': 10, 'duration_frames': 5},
        ],
        'layers': [
          {
            'channel': 0,
            'slot': 1,
            'generation': 0,
            'frame': 480,
            'frame_count': 480,
            'lane_count': 1,
            'filename': 'layer-0-480-1.pcm',
          },
        ],
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [0],
        },
      };
      final manifest = PerformanceManifest(
        slug: 'perf-20260706-143015',
        finalized: true,
        native: native,
      );
      final json = manifest.toJson();
      expect(json['sample_rate'], 48000);
      expect(json['overrun_gaps'], native['overrun_gaps']);
      expect(json['slug'], 'perf-20260706-143015');
      expect(json['finalized'], isTrue);

      final decoded = PerformanceManifest.fromJson(json);
      expect(decoded.sampleRate, 48000);
      expect(decoded.captureFrames, 96000);
      expect(decoded.overrunCount, 2);
      expect(decoded.layers, hasLength(1));
      expect(decoded.layers.single.filename, 'layer-0-480-1.pcm');
      expect(decoded.slug, 'perf-20260706-143015');
      expect(decoded.finalized, isTrue);
      expect(decoded.armSnapshot, isNull);
      expect(decoded.disarmSnapshot, isNull);
    });

    test('stoppedEarly reflects the native field when present', () {
      const manifest = PerformanceManifest(
        slug: 's',
        finalized: true,
        native: {'stopped_early': 'disk_full'},
      );
      expect(manifest.stoppedEarly, 'disk_full');
    });

    test('defaults native-derived fields when absent', () {
      const manifest = PerformanceManifest(
        slug: 's',
        finalized: false,
        native: {},
      );
      expect(manifest.sampleRate, 0);
      expect(manifest.captureFrames, 0);
      expect(manifest.overrunCount, 0);
      expect(manifest.stoppedEarly, isNull);
      expect(manifest.layers, isEmpty);
    });
  });
}
