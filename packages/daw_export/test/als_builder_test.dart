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
  });
}
