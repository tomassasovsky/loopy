import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

void main() {
  group('DawManifestReader.read', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('daw_export_manifest_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('returns null when performance.json is missing', () {
      expect(DawManifestReader.read(dir.path), isNull);
    });

    test('returns null when performance.json is corrupt', () {
      File('${dir.path}/performance.json').writeAsStringSync('{not json');
      expect(DawManifestReader.read(dir.path), isNull);
    });

    test(
      'builds one track with an arrangement clip from a wet stem, preferring '
      'it over dry',
      () {
        Directory('${dir.path}/stems/wet').createSync(recursive: true);
        Directory('${dir.path}/stems/dry').createSync(recursive: true);
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync([0]);
        File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync([0]);
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {'lane': 0, 'deferred': false, 'pcmRef': 'ignored.wav'},
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );

        final project = DawManifestReader.read(dir.path);
        expect(project, isNotNull);
        expect(project!.tracks, hasLength(1));
        expect(
          project.tracks.single.arrangementClip!.fileRef,
          'stems/wet/track0.wav',
        );
        expect(project.tracks.single.arrangementClip!.lengthSeconds, 1.0);
      },
    );

    test('falls back to a dry stem when no wet stem exists', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync([0]);
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {'channel': 0, 'lanes': <dynamic>[]},
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final project = DawManifestReader.read(dir.path);
      expect(
        project!.tracks.single.arrangementClip!.fileRef,
        'stems/dry/track0.wav',
      );
    });

    test(
      'includes one session clip per lane that has a loop export, and no '
      'arrangement clip when no channel-level stem exists',
      () {
        Directory('${dir.path}/loops').createSync(recursive: true);
        File('${dir.path}/loops/track0-lane0.wav').writeAsBytesSync([0]);
        File('${dir.path}/loops/track0-lane1.wav').writeAsBytesSync([0]);
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'loops/track0-lane0.wav',
                    },
                    {
                      'lane': 1,
                      'deferred': false,
                      'pcmRef': 'loops/track0-lane1.wav',
                    },
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );

        final project = DawManifestReader.read(dir.path);
        final track = project!.tracks.single;
        expect(track.sessionClips, hasLength(2));
        // The only behavior unique to this fixture (no stems/wet or
        // stems/dry file for channel 0 at all) is that the track has no
        // arrangement clip — asserted explicitly rather than left to
        // whatever `sessionClips` happens to check.
        expect(track.arrangementClip, isNull);
        // Pins the documented placeholder: a session clip's length is the
        // full capture length until part 11 threads the lane's own settled
        // length through (see the comment at the call site in
        // manifest_reader.dart) — a future change to this value should be a
        // deliberate, reviewed edit to this test, not a silent side effect.
        expect(track.sessionClips.first.lengthSeconds, 1.0);
      },
    );

    test(
      'reads a lane pcmRef verbatim rather than reconstructing a '
      'conventional filename',
      () {
        Directory('${dir.path}/captured').createSync(recursive: true);
        File('${dir.path}/captured/unconventional-name.wav').writeAsBytesSync([
          0,
        ]);
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'captured/unconventional-name.wav',
                    },
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );

        final project = DawManifestReader.read(dir.path);
        expect(
          project!.tracks.single.sessionClips.single.fileRef,
          'captured/unconventional-name.wav',
        );
      },
    );

    test(
      'prefers a disarm-time pcmRef over an arm-time one for the same lane',
      () {
        Directory('${dir.path}/loops').createSync(recursive: true);
        File('${dir.path}/loops/stale.wav').writeAsBytesSync([0]);
        File('${dir.path}/loops/fresh.wav').writeAsBytesSync([0]);
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {'lane': 0, 'deferred': false, 'pcmRef': 'loops/stale.wav'},
                  ],
                },
              ],
            },
            'disarmSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {'lane': 0, 'deferred': false, 'pcmRef': 'loops/fresh.wav'},
                  ],
                },
              ],
            },
            'layers': <dynamic>[],
          }),
        );

        final project = DawManifestReader.read(dir.path);
        expect(
          project!.tracks.single.sessionClips.single.fileRef,
          'loops/fresh.wav',
        );
      },
    );

    test('excludes a channel with no arrangement stem and no lane exports', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {'lane': 0, 'deferred': true},
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final project = DawManifestReader.read(dir.path);
      expect(project!.tracks, isEmpty);
    });
  });
}
