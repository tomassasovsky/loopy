import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/src/daw_project.dart';

/// The fixed pointee id Ableton Live conventionally assigns to the main
/// track's tempo automation target — the main track's `Tempo` element wires
/// its `AutomationTarget` to this id, and the single `AutomationEnvelope`
/// this builder emits targets it right back (`EnvelopeTarget/PointeeId`).
/// Reserved (never handed out by [_IdAllocator]) so the two can never
/// collide with a track/clip/slot id.
///
/// This is a single hardcoded reserved constant because tempo is the only
/// fixed automation target part 9 needs. Part 10 adds per-clip
/// `AutomationLane`s with their own fixed pointee targets (volume/mute/FX
/// params) — when that lands, generalize this into a reserved-id set (or
/// have [_IdAllocator] hand out and track every fixed target itself) rather
/// than adding a second hand-maintained constant that could drift out of
/// sync with this one.
const int _kTempoPointeeId = 8;

/// Nominal sample rate used only for `AudioClip`'s informational
/// `DefaultSampleRate`/`DefaultDuration` fields — cosmetic metadata Ableton
/// re-reads from the actual file on load, not authoritative here since
/// [DawClip]/[DawSessionClip] only carry lengths in seconds.
const int _kNominalSampleRate = 48000;

/// Allocates unique, monotonically increasing element ids, starting past
/// every reserved id ([_kTempoPointeeId]) so a track/clip/slot id can never
/// collide with one Ableton itself expects at a fixed value.
class _IdAllocator {
  int _next = _kTempoPointeeId + 1;

  int next() => _next++;

  /// The value Ableton's `NextPointeeId` element should carry: one past the
  /// highest id this allocator has handed out.
  int get nextPointeeId => _next;
}

/// Builds an Ableton Live 12 `.als` set (gzipped XML) from [project].
///
/// Structural guarantees this builder enforces (see `als_builder_test.dart`
/// for the corresponding assertions):
/// - every `Id`/`PointeeId` pair is internally consistent — the tempo
///   envelope's `PointeeId` always matches the main track's
///   `AutomationTarget` id, and `NextPointeeId` is always one past the
///   highest id actually used;
/// - every `FileRef` is a relative path — an absolute [DawClip.fileRef] or
///   [DawSessionClip.fileRef] throws [ArgumentError] rather than silently
///   emitting a bundle that would break once moved (D-ALS);
/// - every clip has `WarpMode`/`IsWarped` off (D-TEMPO: a captured
///   performance is already sample-accurate at its own tempo, not meant to
///   stretch to the project's);
/// - an empty [DawTrack] (no arrangement clip and no session clips) is
///   never expected here — the caller (a fixture, or `DawManifestReader`)
///   already excludes empty tracks, so this builder does not re-filter
///   [DawProject.tracks].
///
/// The exact Ableton Live XML schema below is built from documented/public
/// knowledge of the Live Set format, not verified against a real
/// Live-12-saved corpus (`test/corpus/README.md` tracks this as a follow-up
/// requiring an actual Ableton Live install) — every acceptance criterion
/// this part's own test suite can enforce (Id/Pointee consistency, relative
/// paths, warp-off, beat math, track/clip counts) is verified regardless of
/// that pending real-world fidelity check.
Uint8List buildAls(DawProject project) {
  final allocator = _IdAllocator();
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<Ableton MajorVersion="5" MinorVersion="12.0_12120" '
      'SchemaChangeCount="3" Creator="Ableton Live 12.0" '
      'Revision="loopy-daw-export">',
    )
    ..writeln('<LiveSet>')
    ..writeln('<Tracks>');

  for (final track in project.tracks) {
    _writeAudioTrack(buffer, track, project.tempoBpm, allocator);
  }

  buffer
    ..writeln('</Tracks>')
    ..writeln(_mainTrack(project.tempoBpm, allocator))
    ..writeln('<NextPointeeId Value="${allocator.nextPointeeId}"/>')
    ..writeln('</LiveSet>')
    ..writeln('</Ableton>');

  final xmlBytes = utf8.encode(buffer.toString());
  return Uint8List.fromList(GZipCodec().encode(xmlBytes));
}

void _writeAudioTrack(
  StringBuffer buffer,
  DawTrack track,
  double tempoBpm,
  _IdAllocator allocator,
) {
  final trackId = allocator.next();
  buffer
    ..writeln('<AudioTrack Id="$trackId">')
    ..writeln('<Name>')
    ..writeln('<EffectiveName Value="${_xmlEscape(track.name)}"/>')
    ..writeln('<UserName Value="${_xmlEscape(track.name)}"/>')
    ..writeln('</Name>')
    ..writeln('<DeviceChain>')
    ..writeln('<MainSequencer>')
    ..writeln('<ClipSlotList>');

  for (final session in track.sessionClips) {
    final slotId = allocator.next();
    final clipId = allocator.next();
    buffer
      ..writeln('<ClipSlot Id="$slotId">')
      ..writeln('<ClipSlot>')
      ..writeln('<Value>')
      ..writeln(
        _audioClip(
          id: clipId,
          time: 0,
          name: 'Lane ${session.laneIndex}',
          fileRef: session.fileRef,
          lengthSeconds: session.lengthSeconds,
          tempoBpm: tempoBpm,
        ),
      )
      ..writeln('</Value>')
      ..writeln('</ClipSlot>')
      ..writeln('</ClipSlot>');
  }

  buffer
    ..writeln('</ClipSlotList>')
    ..writeln('<Arranger>')
    ..writeln('<Events>');
  final arrangement = track.arrangementClip;
  if (arrangement != null) {
    final clipId = allocator.next();
    final startBeats = secondsToBeats(arrangement.startSeconds, tempoBpm);
    buffer.writeln(
      _audioClip(
        id: clipId,
        time: startBeats,
        name: track.name,
        fileRef: arrangement.fileRef,
        lengthSeconds: arrangement.lengthSeconds,
        tempoBpm: tempoBpm,
        startBeatsOverride: startBeats,
      ),
    );
  }
  buffer
    ..writeln('</Events>')
    ..writeln('</Arranger>')
    ..writeln('</MainSequencer>')
    ..writeln('</DeviceChain>')
    ..writeln('</AudioTrack>');
}

String _audioClip({
  required int id,
  required double time,
  required String name,
  required String fileRef,
  required double lengthSeconds,
  required double tempoBpm,
  double? startBeatsOverride,
}) {
  if (_looksAbsolute(fileRef)) {
    throw ArgumentError.value(
      fileRef,
      'fileRef',
      'must be a relative path (D-ALS) — an absolute FileRef would break '
          'the moment the bundle is moved',
    );
  }
  final startBeats = startBeatsOverride ?? 0.0;
  final lengthBeats = secondsToBeats(lengthSeconds, tempoBpm);
  final endBeats = startBeats + lengthBeats;
  final escapedName = _xmlEscape(name);
  final escapedRef = _xmlEscape(fileRef);
  final frames = (lengthSeconds * _kNominalSampleRate).round();
  return '''
<AudioClip Id="$id" Time="$time">
<LomId Value="0"/>
<Name Value="$escapedName"/>
<CurrentStart Value="$startBeats"/>
<CurrentEnd Value="$endBeats"/>
<Loop>
<LoopStart Value="0"/>
<LoopEnd Value="$lengthBeats"/>
<StartRelative Value="0"/>
<LoopOn Value="false"/>
<OutMarker Value="$lengthBeats"/>
<HiddenLoopStart Value="0"/>
<HiddenLoopEnd Value="$lengthBeats"/>
</Loop>
<Disabled Value="false"/>
<SampleRef>
<FileRef>
<RelativePathType Value="1"/>
<RelativePath Value="$escapedRef"/>
<Path Value="$escapedRef"/>
<Type Value="1"/>
</FileRef>
<LastModDate Value="0"/>
<SourceContext/>
<SampleUsageHint Value="0"/>
<DefaultDuration Value="$frames"/>
<DefaultSampleRate Value="$_kNominalSampleRate"/>
</SampleRef>
<WarpMode Value="0"/>
<IsWarped Value="false"/>
</AudioClip>''';
}

String _mainTrack(double tempoBpm, _IdAllocator allocator) {
  final envelopeId = allocator.next();
  return '''
<MainTrack>
<DeviceChain>
<Mixer>
<Tempo>
<LomId Value="0"/>
<Manual Value="$tempoBpm"/>
<AutomationTarget Id="$_kTempoPointeeId">
<LockEnvelope Value="0"/>
</AutomationTarget>
</Tempo>
</Mixer>
</DeviceChain>
<AutomationEnvelopes>
<Envelopes>
<AutomationEnvelope Id="$envelopeId">
<EnvelopeTarget>
<PointeeId Value="$_kTempoPointeeId"/>
</EnvelopeTarget>
<Automation>
<Events>
<FloatEvent Time="-63072000" Value="$tempoBpm"/>
</Events>
</Automation>
</AutomationEnvelope>
</Envelopes>
</AutomationEnvelopes>
</MainTrack>''';
}

/// Converts a duration in seconds to Ableton's beat-time unit at [bpm].
/// Exposed for the test suite's own independent beat-math assertions.
double secondsToBeats(double seconds, double bpm) => seconds * (bpm / 60.0);

bool _looksAbsolute(String path) {
  if (path.startsWith('/') || path.startsWith(r'\')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
