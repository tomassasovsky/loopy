import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/gen/app_localizations.dart';

/// Localized labels for engine enums and formatted values.
extension EngineLocalizations on AppLocalizations {
  String trackStateLabel(TrackState state) => switch (state) {
    TrackState.empty => trackStateEmpty,
    TrackState.recording => trackStateRecording,
    TrackState.overdubbing => trackStateOverdubbing,
    TrackState.playing => trackStatePlaying,
    TrackState.stopped => trackStateStopped,
  };

  String effectTypeLabel(TrackEffectType type) => switch (type) {
    TrackEffectType.none => effectNone,
    TrackEffectType.drive => effectDrive,
    TrackEffectType.filter => effectFilter,
    TrackEffectType.delay => effectDelay,
    TrackEffectType.tremolo => effectTremolo,
    TrackEffectType.octaver => effectOctaver,
    TrackEffectType.echo => effectEcho,
    TrackEffectType.reverb => effectReverb,
  };

  String effectParamLabel(String englishLabel) => switch (englishLabel) {
    'Drive' => paramDrive,
    'Level' => paramLevel,
    'Cutoff' => paramCutoff,
    'Resonance' => paramResonance,
    'Time' => paramTime,
    'Feedback' => paramFeedback,
    'Mix' => paramMix,
    'Rate' => paramRate,
    'Depth' => paramDepth,
    'Shift' => paramShift,
    'Tone' => paramTone,
    'Size' => paramSize,
    'Damping' => paramDamping,
    'Mode' => paramMode,
    _ => englishLabel,
  };

  /// The octaver's algorithm-mode readout: `< 0.5` selects the phase vocoder,
  /// `>= 0.5` selects PSOLA.
  String octaverModeLabel(double value) =>
      value < 0.5 ? octaverModePhaseVocoder : octaverModePsola;

  String formatLocalizedPitchShift(double value) {
    final semitones = ((value - 0.5) * 48).round();
    if (semitones == 0) return pitchUnison;
    final sign = semitones > 0 ? '+' : '-';
    final magnitude = semitones.abs();
    if (magnitude % 12 == 0) {
      return pitchOctaves(sign, magnitude ~/ 12);
    }
    return pitchSemitones(sign, magnitude);
  }

  String loopbackKindLabel(LoopbackKind kind) => switch (kind) {
    LoopbackKind.backendLoopback => loopbackKindBackend,
    LoopbackKind.monitor => loopbackKindMonitor,
    LoopbackKind.virtualDevice => loopbackKindVirtualDevice,
    LoopbackKind.none => '',
  };

  String latencyStateLabel(EngineStatus status) =>
      switch (status.latencyState) {
        LatencyState.done => latencyMs(
          status.measuredLatencyMs.toStringAsFixed(2),
        ),
        LatencyState.measuring => measuringLowercase,
        LatencyState.timeout => noLoopback,
        LatencyState.idle => notMeasured,
      };

  String displayTrackName(String name, int channel) {
    final defaultName = 'TRACK ${channel + 1}';
    if (name == defaultName) {
      return defaultTrackName(channel + 1);
    }
    return name;
  }

  /// What to CALL track [channel], given the rig's [names] — the one resolver
  /// every surface that names a track goes through (#526).
  ///
  /// [displayTrackName] answers the same question but only once the caller has
  /// already found the name, which is why half the app was still printing an
  /// ordinal: the pedal target list, the MIDI-learn labels, the FX bus title
  /// and the rename dialog all had a channel and no list, so they said "Track
  /// 3" while the stage beside them said RHYTHM. This takes the channel and
  /// the list, so having one is enough.
  ///
  /// Out-of-range channels fall back rather than throw: a stale binding names
  /// a track the rig no longer has, and a row that still has to say what it
  /// used to drive is better than a crash.
  String trackName(List<String> names, int channel) => displayTrackName(
    channel >= 0 && channel < names.length
        ? names[channel]
        : 'TRACK ${channel + 1}',
    channel,
  );

  String sampleRateKhzLabel(int rate) {
    final khz = rate / 1000;
    final text = khz == khz.roundToDouble()
        ? khz.toStringAsFixed(0)
        : khz.toStringAsFixed(1);
    return sampleRateKhz(text);
  }

  String bufferHint(int frames) => switch (frames) {
    <= 64 => bufferHint64,
    128 => bufferHint128,
    256 => bufferHint256,
    _ => bufferHint512,
  };

  String sampleRateNote(int rate) => switch (rate) {
    44100 => sampleRateNoteCd,
    48000 => sampleRateNoteStudio,
    96000 => sampleRateNoteHiRes,
    _ => '',
  };

  String setupBlurb(int step) => switch (step) {
    0 => setupBlurbEngine,
    1 => setupBlurbInput,
    _ => setupBlurbReady,
  };

  String loopbackNote(LoopbackInfo loopback) {
    final deviceClause = loopback.deviceName.isNotEmpty
        ? ' (${loopback.deviceName})'
        : '';
    if (loopback.isAutoRoutable) {
      return loopbackDetectedNote(deviceClause);
    }
    return loopbackAvailableNote(
      loopbackKindLabel(loopback.kind),
      deviceClause,
    );
  }
}
