import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

void main() {
  group('DawProject', () {
    test('defaults tempoBpm to 120', () {
      const project = DawProject(tracks: []);
      expect(project.tempoBpm, 120.0);
      expect(project.tracks, isEmpty);
    });

    test('carries an explicit tempo and track list', () {
      const clip = DawClip(
        fileRef: 'stems/wet/track0.wav',
        startSeconds: 0,
        lengthSeconds: 4,
      );
      const session = DawSessionClip(
        laneIndex: 0,
        fileRef: 'loops/track0-lane0.wav',
        lengthSeconds: 1,
      );
      const track = DawTrack(
        name: 'Track 0',
        arrangementClip: clip,
        sessionClips: [session],
      );
      const project = DawProject(tracks: [track], tempoBpm: 140);

      expect(project.tempoBpm, 140.0);
      expect(project.tracks.single.name, 'Track 0');
      expect(project.tracks.single.arrangementClip, clip);
      expect(project.tracks.single.sessionClips, [session]);
    });

    test('a track may have no arrangement clip, only session clips', () {
      const track = DawTrack(
        name: 'Input 1',
        sessionClips: [
          DawSessionClip(
            laneIndex: 0,
            fileRef: 'loops/track1-lane0.wav',
            lengthSeconds: 1,
          ),
        ],
      );
      expect(track.arrangementClip, isNull);
      expect(track.sessionClips, hasLength(1));
    });

    test('DawClip carries fileRef/start/length verbatim', () {
      const clip = DawClip(
        fileRef: 'stems/wet/track0.wav',
        startSeconds: 1.5,
        lengthSeconds: 3.25,
      );
      expect(clip.fileRef, 'stems/wet/track0.wav');
      expect(clip.startSeconds, 1.5);
      expect(clip.lengthSeconds, 3.25);
    });

    test('DawSessionClip carries laneIndex/fileRef/length verbatim', () {
      const clip = DawSessionClip(
        laneIndex: 2,
        fileRef: 'loops/track0-lane2.wav',
        lengthSeconds: 2,
      );
      expect(clip.laneIndex, 2);
      expect(clip.fileRef, 'loops/track0-lane2.wav');
      expect(clip.lengthSeconds, 2.0);
    });
  });
}
