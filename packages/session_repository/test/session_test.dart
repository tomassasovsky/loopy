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

    test('tracks have value equality', () {
      expect(session.tracks.first, isNot(session.tracks[1]));
      expect(session.tracks.first, session.tracks.first);
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
