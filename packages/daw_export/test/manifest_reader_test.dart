import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

/// Writes a minimal `events.log` fixture — see
/// `event_log_reader_test.dart`'s own copy of this helper for the exact
/// on-disk layout this mirrors; duplicated here (not shared) since test
/// helpers in this package are kept file-local by convention.
void _writeLog(
  String path,
  int sampleRate,
  List<(int frame, int code, List<int> payload)> entries,
) {
  final out = BytesBuilder()..add('PLEV'.codeUnits);
  final version = ByteData(4)..setUint32(0, 1, Endian.little);
  out.add(version.buffer.asUint8List());
  final sr = ByteData(4)..setInt32(0, sampleRate, Endian.little);
  out.add(sr.buffer.asUint8List());

  for (final (frame, code, payload) in entries) {
    final header = ByteData(12)
      ..setUint64(0, frame, Endian.little)
      ..setInt32(8, code, Endian.little);
    out.add(header.buffer.asUint8List());
    final padded = List<int>.filled(16, 0);
    for (var i = 0; i < payload.length && i < 16; i++) {
      padded[i] = payload[i];
    }
    out.add(padded);
  }

  File(path).writeAsBytesSync(out.toBytes());
}

List<int> _generic(int argI, double argF) {
  final b = ByteData(16)
    ..setInt32(0, argI, Endian.little)
    ..setFloat32(4, argF, Endian.little);
  return b.buffer.asUint8List();
}

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

    test(
      'builds a volume automation lane from events.log for a track that '
      'also has an arrangement clip',
      () {
        Directory('${dir.path}/stems/wet').createSync(recursive: true);
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync([0]);
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
                      'pcmRef': 'stems/wet/track0.wav',
                    },
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );
        const codeSetVolume = 7;
        _writeLog('${dir.path}/events.log', 48000, [
          (0, codeSetVolume, _generic(0, 0.5)),
          (48000, codeSetVolume, _generic(0, 0.9)),
        ]);

        final project = DawManifestReader.read(dir.path);
        final lanes = project!.tracks.single.automationLanes;
        expect(lanes, hasLength(1));
        expect(lanes.single.target, AutomationTarget.volume);
        expect(lanes.single.breakpoints, hasLength(2));
        expect(lanes.single.breakpoints.first.beat, 0.0);
        expect(lanes.single.breakpoints.last.beat, 2.0); // 1s at 120bpm
      },
    );

    test(
      'builds an activator (mute) automation lane from events.log, '
      'independent of whether a volume lane exists',
      () {
        Directory('${dir.path}/stems/wet').createSync(recursive: true);
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync([0]);
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
                      'pcmRef': 'stems/wet/track0.wav',
                    },
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );
        const codeSetMute = 8;
        _writeLog('${dir.path}/events.log', 48000, [
          (0, codeSetMute, _generic(0, 1)), // muted
          (48000, codeSetMute, _generic(0, 0)), // unmuted
        ]);

        final project = DawManifestReader.read(dir.path);
        final lanes = project!.tracks.single.automationLanes;
        expect(lanes, hasLength(1));
        expect(lanes.single.target, AutomationTarget.activator);
        expect(lanes.single.breakpoints, hasLength(2));
        expect(lanes.single.breakpoints.first.value, 0.0); // muted -> off
        expect(lanes.single.breakpoints.last.value, 1.0); // unmuted -> on
      },
    );

    test(
      'a channel whose single lane has an effects chain resolves a device '
      'chain and prefers the dry stem over wet',
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
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'stems/wet/track0.wav',
                      'effects': [
                        {
                          'type': 3,
                          'params': [0.35, 0.35, 0.35, 0.0],
                        },
                      ],
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
        expect(track.deviceChain, [
          const DawEffect(type: 3, params: [0.35, 0.35, 0.35, 0.0]),
        ]);
        expect(track.deviceChainFallbackReason, isNull);
        expect(track.arrangementClip!.fileRef, 'stems/dry/track0.wav');
      },
    );

    test(
      'a channel with mixed-lane effects chains exports exactly like today '
      '— wet-preferred, no device chain',
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
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'a.wav',
                      'effects': [
                        {
                          'type': 3,
                          'params': [0.35, 0.35, 0.35, 0.0],
                        },
                      ],
                    },
                    {
                      'lane': 1,
                      'deferred': false,
                      'pcmRef': 'b.wav',
                      'effects': [
                        {
                          'type': 7,
                          'params': [0.5, 0.5, 0.35, 0.0],
                        },
                      ],
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
        expect(track.deviceChain, isNull);
        expect(
          track.deviceChainFallbackReason,
          DeviceChainFallbackReason.mixedLaneChains,
        );
        expect(track.arrangementClip!.fileRef, 'stems/wet/track0.wav');
      },
    );

    test(
      'a channel that resolves a device chain but has no dry stem falls '
      'all the way back to wet-preferred with no device chain (D-WETDRY)',
      () {
        Directory('${dir.path}/stems/wet').createSync(recursive: true);
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync([0]);
        // Deliberately no stems/dry/track0.wav.
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
                      'pcmRef': 'stems/wet/track0.wav',
                      'effects': [
                        {
                          'type': 3,
                          'params': [0.35, 0.35, 0.35, 0.0],
                        },
                      ],
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
        expect(track.deviceChain, isNull);
        expect(track.arrangementClip!.fileRef, 'stems/wet/track0.wav');
      },
    );

    test(
      'a channel with no effects on its only lane resolves an empty '
      'device chain but keeps the existing wet-preferred stem behavior',
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
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'stems/wet/track0.wav',
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
        expect(track.deviceChain, isEmpty);
        expect(track.deviceChainFallbackReason, isNull);
        expect(track.arrangementClip!.fileRef, 'stems/wet/track0.wav');
      },
    );

    test(
      'a channel whose chain includes a hosted plugin entry falls back '
      'exactly like today — wet-preferred, no device chain',
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
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'stems/wet/track0.wav',
                      'effects': [
                        {
                          'type': 8,
                          'plugin': {'format': 0, 'id': 'AABB', 'version': 0},
                        },
                      ],
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
        expect(track.deviceChain, isNull);
        expect(
          track.deviceChainFallbackReason,
          DeviceChainFallbackReason.thirdPartyPlugin,
        );
        expect(track.arrangementClip!.fileRef, 'stems/wet/track0.wav');
      },
    );

    test(
      'threads a real, explicit tempoBpm through to the returned DawProject '
      '(and into beat-unit automation conversion)',
      () {
        Directory('${dir.path}/stems/wet').createSync(recursive: true);
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync([0]);
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
                      'pcmRef': 'stems/wet/track0.wav',
                    },
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );
        const codeSetVolume = 7;
        _writeLog('${dir.path}/events.log', 48000, [
          (0, codeSetVolume, _generic(0, 0.5)),
          (48000, codeSetVolume, _generic(0, 0.9)),
        ]);

        final project = DawManifestReader.read(dir.path, tempoBpm: 140);
        expect(project!.tempoBpm, 140.0);
        // At 140 BPM, 1s == 140/60 beats — distinct from the 120-BPM 2.0
        // beats the earlier test at the same frame offset asserts, proving
        // this reader's own internal beat-time conversion (not just the
        // returned DawProject.tempoBpm) uses the real tempo too.
        final lanes = project.tracks.single.automationLanes;
        expect(lanes.single.breakpoints.last.beat, closeTo(140 / 60, 1e-9));
      },
    );

    test(
      'a non-positive tempoBpm (a legacy v3 session, or v4 grid-off content '
      "reporting Session.tempoBpm's 0 = unset) falls back to 120 BPM, same "
      'as omitting the argument entirely',
      () {
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {'tracks': <dynamic>[]},
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );

        expect(DawManifestReader.read(dir.path)!.tempoBpm, 120.0);
        expect(
          DawManifestReader.read(dir.path, tempoBpm: 0)!.tempoBpm,
          120.0,
        );
        expect(
          DawManifestReader.read(dir.path, tempoBpm: -1)!.tempoBpm,
          120.0,
        );
      },
    );

    test('a track with no logged gestures gets no automation lanes', () {
      Directory('${dir.path}/stems/wet').createSync(recursive: true);
      File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync([0]);
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
                    'pcmRef': 'stems/wet/track0.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      // No events.log at all.
      final project = DawManifestReader.read(dir.path);
      expect(project!.tracks.single.automationLanes, isEmpty);
    });
  });
}
