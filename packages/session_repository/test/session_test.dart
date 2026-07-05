import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  const session = Session(
    sampleRate: 48000,
    channels: 1,
    baseLengthFrames: 96000,
    tracks: [
      SessionTrack(
        channel: 0,
        volume: 0.8,
        muted: false,
        multiple: 1,
        lengthFrames: 96000,
        stem: 'track0.wav',
      ),
      SessionTrack(
        channel: 1,
        volume: 0.5,
        muted: true,
        multiple: 2,
        lengthFrames: 192000,
        stem: 'track1.wav',
      ),
    ],
    laneChains: [
      SessionLaneChain(channel: 0, lane: 0, encoded: '[{"t":1}]'),
      SessionLaneChain(channel: 1, lane: 0, encoded: '[{"t":7}]'),
    ],
    monitors: [
      SessionMonitor(
        input: 0,
        enabled: true,
        outputMask: 0x3,
        volume: 0.9,
        muted: false,
        encoded: '[{"t":2}]',
      ),
    ],
  );

  group('Session', () {
    test('round-trips through JSON (including jsonEncode/decode)', () {
      final json = jsonDecode(jsonEncode(session.toJson()));
      expect(Session.fromJson(json as Map<String, dynamic>), session);
    });

    test('serializes the manifest version', () {
      final json = session.toJson();
      expect(json['version'], Session.formatVersion);
      expect(json['baseLengthFrames'], 96000);
    });

    test('serializes the lane chains and monitors (v2)', () {
      final json = session.toJson();
      expect(json['version'], 2);
      expect(json['laneChains'], hasLength(2));
      expect((json['laneChains'] as List).first, {
        'channel': 0,
        'lane': 0,
        'encoded': '[{"t":1}]',
      });
      expect(json['monitors'], hasLength(1));
      expect((json['monitors'] as List).first, {
        'input': 0,
        'enabled': true,
        'outputMask': 0x3,
        'volume': 0.9,
        'muted': false,
        'encoded': '[{"t":2}]',
      });
    });

    test(
      'a v1 manifest (no chains) loads with empty chains, not leftovers',
      () {
        // A legacy bundle omits laneChains / monitors entirely.
        final v1 = {
          'version': 1,
          'sampleRate': 48000,
          'channels': 1,
          'baseLengthFrames': 96000,
          'tracks': [
            {
              'channel': 0,
              'volume': 0.8,
              'muted': false,
              'multiple': 1,
              'lengthFrames': 96000,
              'stem': 'track0.wav',
            },
          ],
        };
        final loaded = Session.fromJson(v1);
        expect(loaded.laneChains, isEmpty);
        expect(loaded.monitors, isEmpty);
        expect(loaded.tracks, hasLength(1));
      },
    );

    test('tracks, lane chains, and monitors have value equality', () {
      expect(session.tracks.first, isNot(session.tracks[1]));
      expect(session.tracks.first, session.tracks.first);
      expect(session.laneChains.first, isNot(session.laneChains[1]));
      expect(session.laneChains.first, session.laneChains.first);
      expect(session.monitors.first, session.monitors.first);
    });

    test('rejects a newer, incompatible manifest version', () {
      final json = session.toJson()..['version'] = Session.formatVersion + 1;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
    });
  });
}
