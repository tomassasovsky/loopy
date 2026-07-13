import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

/// Decompresses and parses [bytes] into a raw XML string — the test suite's
/// own structural assertions are string/regex based rather than a full XML
/// tree parse, since this package deliberately has no XML-parsing
/// dependency (the builder only ever writes; nothing here needs to read its
/// own output back into a tree).
String _decompress(List<int> bytes) => utf8.decode(GZipCodec().decode(bytes));

/// Every `Id="N"` attribute value that appears anywhere in [xml].
Set<int> _allIds(String xml) => RegExp(
  r'Id="(\d+)"',
).allMatches(xml).map((m) => int.parse(m.group(1)!)).toSet();

/// Every `PointeeId Value="N"` value.
Set<int> _allPointeeIds(String xml) => RegExp(
  r'<PointeeId Value="(\d+)"/>',
).allMatches(xml).map((m) => int.parse(m.group(1)!)).toSet();

void main() {
  group('buildAls', () {
    test('emits gzipped XML that decompresses and looks well-formed', () {
      const project = DawProject(
        tracks: [
          DawTrack(
            name: 'Track 0',
            arrangementClip: DawClip(
              fileRef: 'stems/wet/track0.wav',
              startSeconds: 0,
              lengthSeconds: 4,
            ),
          ),
        ],
      );

      final bytes = buildAls(project);
      final xml = _decompress(bytes);

      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(xml, contains('<Ableton'));
      expect(xml, contains('<LiveSet>'));
      expect(xml, contains('</LiveSet>'));
      expect(xml, contains('</Ableton>'));
      // Every opening tag closes — a crude but effective balance check that
      // catches a truncated/malformed builder without an XML parser dep.
      final opens = RegExp('<([A-Za-z]+)[ />]').allMatches(xml).length;
      final closes =
          RegExp('</[A-Za-z]+>').allMatches(xml).length +
          RegExp('<[A-Za-z]+[^>]*/>').allMatches(xml).length;
      expect(opens, closes);
    });

    test('every Id/PointeeId pair is internally consistent', () {
      const project = DawProject(
        tracks: [
          DawTrack(
            name: 'Track 0',
            arrangementClip: DawClip(
              fileRef: 'stems/wet/track0.wav',
              startSeconds: 0,
              lengthSeconds: 4,
            ),
            sessionClips: [
              DawSessionClip(
                laneIndex: 0,
                fileRef: 'loops/track0-lane0.wav',
                lengthSeconds: 1,
              ),
            ],
          ),
          DawTrack(
            name: 'Track 1',
            arrangementClip: DawClip(
              fileRef: 'stems/wet/track1.wav',
              startSeconds: 0,
              lengthSeconds: 4,
            ),
          ),
        ],
      );

      final xml = _decompress(buildAls(project));
      final ids = _allIds(xml);
      final pointeeIds = _allPointeeIds(xml);

      // Every PointeeId a reader would need to resolve actually exists as
      // some element's Id.
      for (final pointee in pointeeIds) {
        expect(
          ids,
          contains(pointee),
          reason: 'PointeeId $pointee has no matching Id',
        );
      }

      // NextPointeeId is strictly past every id actually used.
      final nextPointeeId = int.parse(
        RegExp(r'<NextPointeeId Value="(\d+)"/>').firstMatch(xml)!.group(1)!,
      );
      expect(ids, everyElement(lessThan(nextPointeeId)));

      // No two elements share an Id.
      final idList = RegExp(
        r'Id="(\d+)"',
      ).allMatches(xml).map((m) => int.parse(m.group(1)!)).toList();
      expect(idList.toSet().length, idList.length);

      // The specific pair this whole scheme exists for: the tempo's
      // AutomationTarget id and the AutomationEnvelope's EnvelopeTarget/
      // PointeeId must reference each other exactly — not merely "some Id
      // somewhere," which the checks above alone would still pass even if
      // the two were pointing at unrelated ids (verified by mutation:
      // changing the envelope's PointeeId away from the AutomationTarget's
      // id makes only this assertion fail).
      final automationTargetId = int.parse(
        RegExp(
          r'<AutomationTarget Id="(\d+)">',
        ).firstMatch(xml)!.group(1)!,
      );
      final envelopeTargetPointeeId = int.parse(
        RegExp(
          r'<EnvelopeTarget>\s*<PointeeId Value="(\d+)"/>',
        ).firstMatch(xml)!.group(1)!,
      );
      expect(envelopeTargetPointeeId, automationTargetId);
    });

    test(
      'throws on an absolute FileRef rather than emitting a broken bundle',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: '/Users/someone/loopy/stems/wet/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
            ),
          ],
        );

        expect(() => buildAls(project), throwsArgumentError);
      },
    );

    test('throws on a Windows-style absolute FileRef', () {
      const project = DawProject(
        tracks: [
          DawTrack(
            name: 'Track 0',
            arrangementClip: DawClip(
              fileRef: r'C:\loopy\stems\wet\track0.wav',
              startSeconds: 0,
              lengthSeconds: 4,
            ),
          ),
        ],
      );

      expect(() => buildAls(project), throwsArgumentError);
    });

    test('accepts a relative FileRef with no leading slash', () {
      const project = DawProject(
        tracks: [
          DawTrack(
            name: 'Track 0',
            arrangementClip: DawClip(
              fileRef: 'stems/wet/track0.wav',
              startSeconds: 0,
              lengthSeconds: 4,
            ),
          ),
        ],
      );

      expect(() => buildAls(project), returnsNormally);
    });

    test('every clip has warp off', () {
      const project = DawProject(
        tracks: [
          DawTrack(
            name: 'Track 0',
            arrangementClip: DawClip(
              fileRef: 'stems/wet/track0.wav',
              startSeconds: 0,
              lengthSeconds: 4,
            ),
            sessionClips: [
              DawSessionClip(
                laneIndex: 0,
                fileRef: 'loops/track0-lane0.wav',
                lengthSeconds: 1,
              ),
            ],
          ),
        ],
      );

      final xml = _decompress(buildAls(project));
      final warpMatches = RegExp(
        '<IsWarped Value="(true|false)"/>',
      ).allMatches(xml);
      expect(warpMatches, isNotEmpty);
      for (final m in warpMatches) {
        expect(m.group(1), 'false');
      }
    });

    test('arrangement clip start/length are correct beat units at 120 BPM', () {
      const project = DawProject(
        tracks: [
          DawTrack(
            name: 'Track 0',
            arrangementClip: DawClip(
              fileRef: 'stems/wet/track0.wav',
              startSeconds: 2,
              lengthSeconds: 4,
            ),
          ),
        ],
      );

      final xml = _decompress(buildAls(project));
      // At 120 BPM, 1 beat == 0.5s, so 2.0s -> 4.0 beats, 4.0s -> 8.0 beats.
      expect(secondsToBeats(2, 120), 4.0);
      expect(secondsToBeats(4, 120), 8.0);
      expect(xml, contains('<CurrentStart Value="4.0"/>'));
      expect(xml, contains('<CurrentEnd Value="12.0"/>'));
      expect(xml, contains('<LoopEnd Value="8.0"/>'));
    });

    test('one session clip per (track, lane) fixture entry', () {
      const project = DawProject(
        tracks: [
          DawTrack(
            name: 'Track 0',
            sessionClips: [
              DawSessionClip(
                laneIndex: 0,
                fileRef: 'loops/track0-lane0.wav',
                lengthSeconds: 1,
              ),
              DawSessionClip(
                laneIndex: 1,
                fileRef: 'loops/track0-lane1.wav',
                lengthSeconds: 1,
              ),
            ],
          ),
        ],
      );

      final xml = _decompress(buildAls(project));
      expect(RegExp(r'<ClipSlot Id="\d+">').allMatches(xml).length, 2);
      expect(xml, contains('loops/track0-lane0.wav'));
      expect(xml, contains('loops/track0-lane1.wav'));
    });

    test(
      'one audio track per non-empty entry; caller-excluded empty tracks '
      'never appear',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/wet/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
            ),
            DawTrack(
              name: 'Input 1',
              sessionClips: [
                DawSessionClip(
                  laneIndex: 0,
                  fileRef: 'loops/track1-lane0.wav',
                  lengthSeconds: 1,
                ),
              ],
            ),
          ],
        );

        final xml = _decompress(buildAls(project));
        expect(RegExp(r'<AudioTrack Id="\d+">').allMatches(xml).length, 2);
        expect(xml, contains('Track 0'));
        expect(xml, contains('Input 1'));
      },
    );

    test('an empty DawProject still produces a valid, openable skeleton', () {
      const project = DawProject(tracks: []);
      final xml = _decompress(buildAls(project));
      expect(xml, contains('<Tracks>'));
      expect(xml, contains('<MainTrack>'));
      expect(RegExp('<AudioTrack').allMatches(xml), isEmpty);
    });

    test(
      'a volume automation lane emits FloatEvents whose EnvelopeTarget '
      'PointeeId matches the track mixer Volume AutomationTarget id',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/wet/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              automationLanes: [
                AutomationLane(
                  target: AutomationTarget.volume,
                  breakpoints: [
                    AutomationBreakpoint(beat: 0, value: 0.5),
                    AutomationBreakpoint(beat: 4, value: 0.9),
                  ],
                ),
              ],
            ),
          ],
        );

        final xml = _decompress(buildAls(project));
        expect(xml, contains('<Volume>'));
        final volumeTargetId = int.parse(
          RegExp(
            r'<Volume>.*?<AutomationTarget Id="(\d+)">',
            dotAll: true,
          ).firstMatch(xml)!.group(1)!,
        );
        // The specific pair, not just "some pointee id somewhere" —
        // extracts the PointeeId of the one envelope that actually contains
        // a FloatEvent and asserts it equals Volume's own AutomationTarget
        // id exactly, the same rigor as the tempo envelope's own test.
        final floatEnvelopePointeeId = int.parse(
          RegExp(
            r'<PointeeId Value="(\d+)"/>\s*</EnvelopeTarget>\s*<Automation>'
            r'\s*<Events>\s*<FloatEvent',
          ).firstMatch(xml)!.group(1)!,
        );
        expect(floatEnvelopePointeeId, volumeTargetId);

        final floatEvents = RegExp(
          r'<FloatEvent Time="([\d.]+)" Value="([\d.]+)"/>',
        ).allMatches(xml).toList();
        expect(floatEvents, hasLength(2));
        expect(double.parse(floatEvents[0].group(1)!), 0.0);
        expect(double.parse(floatEvents[0].group(2)!), 0.5);
        expect(double.parse(floatEvents[1].group(1)!), 4.0);
        expect(double.parse(floatEvents[1].group(2)!), 0.9);
      },
    );

    test(
      'an activator (mute) automation lane emits step-shaped BoolEvents, '
      'never interpolated FloatEvents, at the exact logged beats',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/wet/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              automationLanes: [
                AutomationLane(
                  target: AutomationTarget.activator,
                  breakpoints: [
                    AutomationBreakpoint(beat: 0, value: 1),
                    AutomationBreakpoint(beat: 2, value: 0),
                    AutomationBreakpoint(beat: 3, value: 1),
                  ],
                ),
              ],
            ),
          ],
        );

        final xml = _decompress(buildAls(project));
        expect(xml, contains('<TrackActivator>'));
        final activatorTargetId = int.parse(
          RegExp(
            r'<TrackActivator>.*?<AutomationTarget Id="(\d+)">',
            dotAll: true,
          ).firstMatch(xml)!.group(1)!,
        );
        // The specific pair, not just "some pointee id somewhere" — same
        // rigor as the volume test and the baseline tempo test above.
        final boolEnvelopePointeeId = int.parse(
          RegExp(
            r'<PointeeId Value="(\d+)"/>\s*</EnvelopeTarget>\s*<Automation>'
            r'\s*<Events>\s*<BoolEvent',
          ).firstMatch(xml)!.group(1)!,
        );
        expect(boolEnvelopePointeeId, activatorTargetId);

        final boolEvents = RegExp(
          r'<BoolEvent Time="([\d.]+)" Value="(true|false)"/>',
        ).allMatches(xml).toList();
        expect(boolEvents, hasLength(3));
        expect(boolEvents[0].group(1), '0.0');
        expect(boolEvents[0].group(2), 'true');
        expect(boolEvents[1].group(1), '2.0');
        expect(boolEvents[1].group(2), 'false');
        expect(boolEvents[2].group(1), '3.0');
        expect(boolEvents[2].group(2), 'true');
      },
    );

    test(
      'a track with both a volume and an activator lane gets two distinct '
      'AutomationTarget ids and two distinct envelopes, both consistent',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/wet/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              automationLanes: [
                AutomationLane(
                  target: AutomationTarget.volume,
                  breakpoints: [
                    AutomationBreakpoint(beat: 0, value: 0.5),
                    AutomationBreakpoint(beat: 4, value: 0.9),
                  ],
                ),
                AutomationLane(
                  target: AutomationTarget.activator,
                  breakpoints: [
                    AutomationBreakpoint(beat: 0, value: 1),
                    AutomationBreakpoint(beat: 2, value: 0),
                  ],
                ),
              ],
            ),
          ],
        );

        final xml = _decompress(buildAls(project));
        expect(RegExp('<FloatEvent').allMatches(xml), isNotEmpty);
        expect(RegExp('<BoolEvent').allMatches(xml), isNotEmpty);
        expect(
          RegExp(r'<AutomationEnvelope Id="\d+">').allMatches(xml).length,
          3,
        ); // tempo + volume + activator
        // No two Ids collide anywhere, including the two new automation
        // targets and their envelopes.
        final idList = RegExp(
          r'Id="(\d+)"',
        ).allMatches(xml).map((m) => int.parse(m.group(1)!)).toList();
        expect(idList.toSet().length, idList.length);
      },
    );

    test(
      'a track with two automation lanes for the same target throws, '
      'rather than silently picking one',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              automationLanes: [
                AutomationLane(
                  target: AutomationTarget.volume,
                  breakpoints: [AutomationBreakpoint(beat: 0, value: 0.5)],
                ),
                AutomationLane(
                  target: AutomationTarget.volume,
                  breakpoints: [AutomationBreakpoint(beat: 0, value: 0.9)],
                ),
              ],
            ),
          ],
        );

        expect(() => buildAls(project), throwsArgumentError);
      },
    );

    test(
      'a track with no automation lanes emits no per-track '
      'Volume/TrackActivator mixer entries (the MainTrack still has its '
      'own Mixer/Tempo, which this must not be confused with)',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/wet/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
            ),
          ],
        );
        final xml = _decompress(buildAls(project));
        // The MainTrack's own Mixer/Tempo is always present.
        expect(xml, contains('<Mixer>'));
        expect(xml, isNot(contains('<Volume>')));
        expect(xml, isNot(contains('<TrackActivator>')));
        // Only the tempo envelope exists — no per-track automation envelope.
        expect(
          RegExp(r'<AutomationEnvelope Id="\d+">').allMatches(xml),
          hasLength(1),
        );
      },
    );

    test(
      'a track with deviceChain: null (every existing fixture, unchanged) '
      'emits no <Devices> block at all — the part-10 regression guard',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/wet/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
            ),
          ],
        );
        final xml = _decompress(buildAls(project));
        expect(xml, isNot(contains('<Devices>')));
        expect(xml, isNot(contains('Vst3PluginDevice')));
      },
    );

    test(
      'a track with an empty (resolved-but-no-effects) deviceChain also '
      'emits no <Devices> block',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/dry/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              deviceChain: [],
            ),
          ],
        );
        final xml = _decompress(buildAls(project));
        expect(xml, isNot(contains('<Devices>')));
      },
    );

    test(
      'a single-effect device chain emits one Vst3PluginDevice referencing '
      "the plugin's permanent class id, with its param values in order",
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/dry/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              deviceChain: [
                DawEffect(type: kFxDelay, params: [0.35, 0.35, 0.35, 0.0]),
              ],
            ),
          ],
        );
        final xml = _decompress(buildAls(project));
        expect(xml, contains('<Devices>'));
        expect(
          RegExp('<Vst3PluginDevice').allMatches(xml),
          hasLength(1),
        );
        expect(
          xml,
          contains('<Uid Value="${loopyVst3Plugins[kFxDelay]!.classId}"/>'),
        );
        // Delay's controller registers exactly 3 real parameters
        // (Time/Feedback/Mix) — the 4th, always-present padding slot
        // (kTrackEffectParams) is NOT emitted, since it doesn't correspond
        // to any parameter Delay's own controller.cpp registers.
        final paramValues = RegExp(
          r'<ParameterValue Value="([\d.]+)"/>',
        ).allMatches(xml).map((m) => double.parse(m.group(1)!)).toList();
        expect(paramValues, [0.35, 0.35, 0.35]);
        expect(xml, contains('<NumParameters Value="3"/>'));
      },
    );

    test(
      'a plugin with fewer real parameters than the always-4-wide padded '
      'params array emits only its real parameter count, not the padding',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/dry/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              // Drive's controller registers exactly 2 real parameters
              // (Drive/Level); the trailing two entries are the manifest's
              // always-4-wide padding, unused by Drive.
              deviceChain: [
                DawEffect(type: kFxDrive, params: [0.5, 0.8, 0.0, 0.0]),
              ],
            ),
          ],
        );
        final xml = _decompress(buildAls(project));
        expect(
          RegExp('<PluginFloatParameter').allMatches(xml),
          hasLength(2),
        );
        final paramValues = RegExp(
          r'<ParameterValue Value="([\d.]+)"/>',
        ).allMatches(xml).map((m) => double.parse(m.group(1)!)).toList();
        expect(paramValues, [0.5, 0.8]);
        expect(xml, contains('<NumParameters Value="2"/>'));
      },
    );

    test(
      'a multi-effect device chain emits one Vst3PluginDevice per entry, '
      'in the same order as the resolved chain',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/dry/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              deviceChain: [
                DawEffect(type: kFxDrive, params: [0.5, 0.8, 0.0, 0.0]),
                DawEffect(type: kFxDelay, params: [0.35, 0.35, 0.35, 0.0]),
                DawEffect(type: kFxReverb, params: [0.5, 0.5, 0.35, 0.0]),
              ],
            ),
          ],
        );
        final xml = _decompress(buildAls(project));
        expect(
          RegExp('<Vst3PluginDevice').allMatches(xml),
          hasLength(3),
        );
        // Order-sensitive: Drive's Uid appears before Delay's, which
        // appears before Reverb's — not just "all three present somewhere."
        final driveIndex = xml.indexOf(loopyVst3Plugins[kFxDrive]!.classId);
        final delayIndex = xml.indexOf(loopyVst3Plugins[kFxDelay]!.classId);
        final reverbIndex = xml.indexOf(loopyVst3Plugins[kFxReverb]!.classId);
        expect(driveIndex, greaterThan(-1));
        expect(delayIndex, greaterThan(driveIndex));
        expect(reverbIndex, greaterThan(delayIndex));
      },
    );

    test(
      'every Id in a device-chain-bearing track stays internally consistent '
      'with the rest of the Id/PointeeId scheme',
      () {
        const project = DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              arrangementClip: DawClip(
                fileRef: 'stems/dry/track0.wav',
                startSeconds: 0,
                lengthSeconds: 4,
              ),
              deviceChain: [
                DawEffect(type: kFxFilter, params: [0.5, 0.2, 0.0, 0.0]),
              ],
              automationLanes: [
                AutomationLane(
                  target: AutomationTarget.volume,
                  breakpoints: [AutomationBreakpoint(beat: 0, value: 0.8)],
                ),
              ],
            ),
          ],
        );

        final xml = _decompress(buildAls(project));
        final ids = _allIds(xml);
        final nextPointeeId = int.parse(
          RegExp(r'<NextPointeeId Value="(\d+)"/>').firstMatch(xml)!.group(1)!,
        );
        expect(ids, everyElement(lessThan(nextPointeeId)));
        final idList = RegExp(
          r'Id="(\d+)"',
        ).allMatches(xml).map((m) => int.parse(m.group(1)!)).toList();
        expect(idList.toSet().length, idList.length);
      },
    );
  });
}
