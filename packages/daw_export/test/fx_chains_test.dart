import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

void main() {
  group('FxChainsWriter.render', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('daw_export_fx_chains_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('returns null when performance.json is missing', () {
      expect(FxChainsWriter.render(dir.path), isNull);
    });

    test('returns null when performance.json is corrupt', () {
      File('${dir.path}/performance.json').writeAsStringSync('{not json');
      expect(FxChainsWriter.render(dir.path), isNull);
    });

    test('returns an empty summary when there is nothing to chain', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {'tracks': <dynamic>[]},
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      expect(FxChainsWriter.render(dir.path), isEmpty);
    });

    test('renders a built-in effect chain with its normalized params', () {
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
                    'effects': [
                      {
                        'type': 1,
                        'params': [0.5, 0.8, 0.0, 0.0],
                      },
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

      final text = FxChainsWriter.render(dir.path);
      expect(text, isNotNull);
      expect(text, contains('Track 0 / Lane 0:'));
      expect(text, contains('1. Drive (params: 0.50, 0.80, 0.00, 0.00)'));
      expect(text, contains('2. Reverb (params: 0.50, 0.50, 0.35, 0.00)'));
    });

    test('renders a lane with no effects explicitly', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {'lane': 0, 'deferred': false, 'effects': <dynamic>[]},
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final text = FxChainsWriter.render(dir.path);
      expect(text, contains('Track 0 / Lane 0:'));
      expect(text, contains('(no effects)'));
    });

    test(
      'renders a plugin entry with its format/id/version and the '
      'offline dry-passthrough note',
      () {
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
                      'effects': [
                        {
                          'type': 8,
                          'plugin': {
                            'format': 0,
                            'id': 'abc123',
                            // 1<<16 | 2<<8 | 3 -> v1.2.3
                            'version': (1 << 16) | (2 << 8) | 3,
                          },
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

        final text = FxChainsWriter.render(dir.path);
        expect(
          text,
          contains(
            '1. Plugin: VST3 abc123 v1.2.3 [rendered as dry passthrough]',
          ),
        );
      },
    );

    test('renders an unversioned plugin as vunknown', () {
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
                    'effects': [
                      {
                        'type': 8,
                        'plugin': {
                          'format': 1,
                          'id': 'clap-thing',
                          'version': 0,
                        },
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

      final text = FxChainsWriter.render(dir.path);
      expect(
        text,
        contains(
          '1. Plugin: CLAP clap-thing vunknown [rendered as dry passthrough]',
        ),
      );
    });

    test(
      'reads effects only from armSnapshot — a disarmSnapshot entry never '
      'carries effects (docs/design/performance-manifest-format.md), and '
      'even a defensively-malformed one carrying it anyway is ignored',
      () {
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
                      'effects': [
                        {
                          'type': 1,
                          'params': [0.1, 0.1, 0.0, 0.0],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
            // Real writers never emit `effects` here — this is exactly
            // the malformed-input shape being defended against.
            'disarmSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {
                      'lane': 0,
                      'deferred': false,
                      'effects': [
                        {
                          'type': 2,
                          'params': [0.9, 0.9, 0.0, 0.0],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
            'layers': <dynamic>[],
          }),
        );

        final text = FxChainsWriter.render(dir.path);
        expect(text, contains('Drive'));
        expect(text, isNot(contains('Filter')));
      },
    );
  });
}
