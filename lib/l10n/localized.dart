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

  /// What to CALL track [channel] — its name, or the localized default when
  /// it has none.
  ///
  /// The one place that answers this. Every surface that identifies a track
  /// goes through here: a rig named `drums / bass / rhythm / lead` should not
  /// read `Track 1 … Track 4` the moment you leave the stage (#526). Falls
  /// back to the ordinal only for a channel the names list does not cover.
  String trackName(List<String> names, int channel) =>
      channel >= 0 && channel < names.length
      ? displayTrackName(names[channel], channel)
      : trackNumberLabel(channel + 1);

  /// What to CALL hardware input [input] — the name it was given, or the
  /// ordinal when it has none. The input-side twin of [trackName].
  String inputName(List<String> names, int input) {
    final given = input >= 0 && input < names.length ? names[input] : '';
    return given.isEmpty ? inputChannelLabel(input + 1) : given;
  }

  String displayTrackName(String name, int channel) {
    final defaultName = 'TRACK ${channel + 1}';
    if (name == defaultName) {
      return defaultTrackName(channel + 1);
    }
    return name;
  }

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
