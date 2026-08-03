import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

/// Copies the named `test/corpus/manifests/` fixture into [dir] as its
/// `performance.json` — see that directory's README for what each fixture
/// pins. Duplicated in `manifest_reader_test.dart` rather than shared, per
/// this package's file-local test-helper convention.
void _installCorpusManifest(Directory dir, String name) {
  // `flutter test packages/daw_export` runs from the repo root, a bare
  // `flutter test` inside the package runs from the package root — resolve
  // against both rather than assuming either.
  for (final base in const [
    'test/corpus/manifests',
    'packages/daw_export/test/corpus/manifests',
  ]) {
    final file = File('$base/$name');
    if (file.existsSync()) {
      file.copySync('${dir.path}/performance.json');
      return;
    }
  }
  fail('corpus fixture $name not found from ${Directory.current.path}');
}

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

  group('FxChainsWriter.render FX v3 stages', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('daw_export_fx_stages_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('marks a bypassed slot without hiding it', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'fxStagesVersion': 1,
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'effects': [
                      {
                        'type': 1,
                        'params': [0.5, 0.8, 0.0, 0.0],
                      },
                      {
                        'type': 7,
                        'params': [0.5, 0.5, 0.35, 0.0],
                        'enabled': false,
                      },
                    ],
                  },
                ],
              },
            ],
          },
        }),
      );

      final text = FxChainsWriter.render(dir.path)!;
      expect(text, contains('1. Drive (params: 0.50, 0.80, 0.00, 0.00)\n'));
      expect(
        text,
        contains('2. Reverb (params: 0.50, 0.50, 0.35, 0.00) [bypassed]'),
      );
    });

    test('marks a bypassed lane chain in its heading', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'fxStagesVersion': 1,
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'chainEnabled': false,
                    'effects': [
                      {
                        'type': 1,
                        'params': [0.5, 0.8, 0.0, 0.0],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        }),
      );

      final text = FxChainsWriter.render(dir.path)!;
      expect(text, contains('Track 0 / Lane 0 [chain bypassed]:'));
      // Bypassed, but still reported — the entries are what the manifest
      // recorded, and hiding them would lose the rig.
      expect(text, contains('1. Drive'));
    });

    test(
      'renders Track bus and Master sections after every per-lane section, '
      'with the manifest-only note',
      () {
        _installCorpusManifest(dir, 'fx-stages-v1.json');

        final text = FxChainsWriter.render(dir.path)!;

        expect(text, contains('Track 0 / Lane 0:'));
        expect(text, contains('Track 0 / Lane 1:'));
        expect(text, contains('Track 1 / Lane 0 [chain bypassed]:'));
        expect(text, contains('Track 0 / Bus:'));
        expect(text, contains('Track 1 / Bus [chain bypassed]:'));
        expect(text, contains('Master:'));

        // Every lane section precedes every bus section, and Master is last.
        expect(
          text.indexOf('Track 1 / Lane 0'),
          lessThan(text.indexOf('Track 0 / Bus')),
        );
        expect(
          text.indexOf('Track 1 / Bus'),
          lessThan(text.indexOf('Master:')),
        );

        expect(
          text,
          contains(
            'Note: Track (bus) and Master chains are recorded in the '
            'manifest only.',
          ),
        );
      },
    );

    test('renders bus and master entries with their own bypass bits', () {
      _installCorpusManifest(dir, 'fx-stages-v1.json');

      final text = FxChainsWriter.render(dir.path)!;

      expect(text, contains('1. Delay (params: 0.40, 0.40, 0.40, 0.00)\n'));
      expect(text, contains('1. Filter (params: 0.60, 0.20, 0.00, 0.00)\n'));
      expect(
        text,
        contains('2. Echo (params: 0.25, 0.50, 0.50, 0.00) [bypassed]'),
      );
    });

    test(
      'renders a Master section for a bypassed insert that has no entries',
      () {
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'fxStagesVersion': 1,
              'tracks': <dynamic>[],
              'masterChainEnabled': false,
            },
          }),
        );

        final text = FxChainsWriter.render(dir.path)!;
        expect(text, contains('Master [chain bypassed]:'));
        expect(text, contains('(no effects)'));
      },
    );

    test('omits the Master section entirely when the insert is untouched', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'fxStagesVersion': 1,
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'effects': [
                      {
                        'type': 1,
                        'params': [0.5, 0.8, 0.0, 0.0],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        }),
      );

      final text = FxChainsWriter.render(dir.path)!;
      expect(text, isNot(contains('Master')));
      // No bus stage was written, so the note has nothing to disclaim.
      expect(text, isNot(contains('manifest only')));
    });

    test(
      'a legacy pre-FX-v3 manifest renders its lane sections unchanged, with '
      'no bus sections, no bypass markers and no note',
      () {
        _installCorpusManifest(dir, 'legacy-pre-fx-v3.json');

        final text = FxChainsWriter.render(dir.path)!;

        expect(text, contains('Track 0 / Lane 0:'));
        expect(text, contains('Track 0 / Lane 1:'));
        expect(text, contains('1. Drive (params: 0.50, 0.80, 0.00, 0.00)'));
        expect(text, isNot(contains('Bus')));
        expect(text, isNot(contains('Master')));
        expect(text, isNot(contains('bypassed')));
        expect(text, isNot(contains('manifest only')));
      },
    );

    test(
      'a malformed manifest degrades to a summary, never a thrown TypeError',
      () {
        // render() promises a graceful null on a corrupt manifest, and its
        // catch covers jsonDecode's FormatException only — a bad cast in the
        // stage parsing would escape that promise and take down an export
        // that has already written its .als.
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'fxStagesVersion': 1,
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {
                      'lane': 0,
                      // Not a bool.
                      'chainEnabled': 'nope',
                      'effects': [
                        {
                          'type': 1,
                          'params': [0.5, 0.8, 0.0, 0.0],
                        },
                        // Not a map.
                        42,
                      ],
                    },
                  ],
                },
              ],
              // Not a list of maps.
              'trackChains': [1, 2],
              // Not a list.
              'masterEffects': 'nonsense',
            },
          }),
        );

        final text = FxChainsWriter.render(dir.path);
        expect(text, isNotNull);
        // The one well-formed entry still reports; the junk is dropped, and
        // an unreadable chain flag reads as engaged.
        expect(text, contains('Track 0 / Lane 0:'));
        expect(text, contains('1. Drive'));
        // No bus section could be written, so the note that disclaims one
        // must not appear either.
        expect(text, isNot(contains('manifest only')));
      },
    );

    test('a trackChains entry with no channel is skipped, not crashed on', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'fxStagesVersion': 1,
            'tracks': <dynamic>[],
            'trackChains': [
              <String, dynamic>{'chainEnabled': false},
              {
                'channel': 2,
                'effects': [
                  {
                    'type': 1,
                    'params': [0.1, 0.0, 0.0, 0.0],
                  },
                ],
              },
            ],
          },
        }),
      );

      final text = FxChainsWriter.render(dir.path)!;
      expect(text, contains('Track 2 / Bus:'));
      expect('Bus'.allMatches(text).length, 1);
    });
  });
}
