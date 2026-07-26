import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  group('FxRack formatVersion migration', () {
    test('v5 writes trackRacks and formatVersion 5', () {
      const session = Session(
        sampleRate: 48000,
        channels: 1,
        baseLengthFrames: 0,
        tracks: [],
        trackRacks: [
          SessionTrackRack(
            channel: 0,
            preEncoded: 'd',
            postEncoded: 'r',
            liveSignal: 'auto',
          ),
        ],
        monitors: [
          SessionMonitor(
            input: 0,
            enabled: true,
            outputMask: 3,
            volume: 1,
            muted: false,
            encoded: 'post',
            preEncoded: 'pre',
          ),
        ],
      );
      final json = session.toJson();
      expect(json['version'], Session.formatVersion);
      expect(Session.formatVersion, 5);
      expect(json['trackRacks'], isNotEmpty);
      final roundtrip = Session.fromJson(json);
      expect(roundtrip.trackRacks.single.liveSignal, 'auto');
      expect(roundtrip.monitors.single.preEncoded, 'pre');
    });

    test('v4 laneChains + monitor encoded load as Post racks fields', () {
      final session = Session.fromJson({
        'version': 4,
        'sampleRate': 48000,
        'channels': 1,
        'baseLengthFrames': 0,
        'tracks': <dynamic>[],
        'laneChains': [
          {'channel': 0, 'lane': 0, 'encoded': 'lane0post'},
          {'channel': 0, 'lane': 1, 'encoded': 'lane1ignored'},
        ],
        'monitors': [
          {
            'input': 0,
            'enabled': true,
            'outputMask': 3,
            'volume': 1.0,
            'muted': false,
            'encoded': 'inputPost',
          },
        ],
      });
      expect(session.trackRacks, isEmpty);
      expect(session.laneChains.first.encoded, 'lane0post');
      expect(session.monitors.single.encoded, 'inputPost');
      expect(session.monitors.single.preEncoded, '');
    });
  });
}
