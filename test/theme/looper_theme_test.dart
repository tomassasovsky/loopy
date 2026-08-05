import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/theme.dart';

void main() {
  group('peakMeterFill', () {
    test('returns 0 for non-positive peaks', () {
      expect(peakMeterFill(0), 0);
      expect(peakMeterFill(-0.5), 0);
    });

    test('maps full scale to 1 and uses sqrt compression', () {
      expect(peakMeterFill(1), 1);
      expect(peakMeterFill(0.25), closeTo(sqrt(0.25), 1e-12));
      expect(peakMeterFill(0.5), closeTo(sqrt(0.5), 1e-12));
    });

    test('clamps peaks above 1', () {
      expect(peakMeterFill(2), 1);
    });
  });

  group('LooperTheme', () {
    const theme = LooperTheme(
      tileBackground: Color(0xFF111111),
      tileBorder: Color(0xFF222222),
      waveformColors: {
        LooperMeterState.playing: Color(0xFF4CDA4A),
        LooperMeterState.recording: Color(0xFFFF1744),
      },
      waveformBackground: Color(0xFF000000),
      recordColor: Color(0xFFFF1744),
      fxColor: Color(0xFF3B82F6),
      recordMeterColors: {
        LooperMeterState.playing: Color(0xFF00FF00),
        LooperMeterState.muted: Color(0xFFFFFFFF),
      },
      muteMeterColors: {
        LooperMeterState.playing: Color(0xFF0000FF),
      },
      indicatorColors: {
        TrackIndicator.idle: Color(0xFF3A3F49),
        TrackIndicator.play: Color(0xFF4CDA4A),
        TrackIndicator.record: Color(0xFFFF1744),
      },
      toolbarIconColor: Color(0xFFB0B3BC),
    );

    test('meterColor picks the table for the current mode', () {
      // Record mode uses recordMeterColors; mute mode uses muteMeterColors.
      expect(
        theme.meterColor(
          LooperMeterState.playing,
          mode: InteractionMode.record,
        ),
        const Color(0xFF00FF00),
      );
      expect(
        theme.meterColor(LooperMeterState.playing, mode: InteractionMode.mute),
        const Color(0xFF0000FF),
      );
      // A state the active table omits resolves to transparent.
      expect(
        theme.meterColor(
          LooperMeterState.stopped,
          mode: InteractionMode.record,
        ),
        Colors.transparent,
      );
      expect(
        theme.meterColor(LooperMeterState.muted, mode: InteractionMode.mute),
        Colors.transparent,
      );
      // FX mode shares the mute table — it is a mixing view, and the meters
      // mean exactly what they mean there.
      expect(
        theme.meterColor(LooperMeterState.playing, mode: InteractionMode.fx),
        theme.meterColor(LooperMeterState.playing, mode: InteractionMode.mute),
      );
    });

    test('indicatorColor picks the color for the indicator', () {
      expect(
        theme.indicatorColor(TrackIndicator.idle),
        const Color(0xFF3A3F49),
      );
      expect(
        theme.indicatorColor(TrackIndicator.play),
        const Color(0xFF4CDA4A),
      );
      expect(
        theme.indicatorColor(TrackIndicator.record),
        const Color(0xFFFF1744),
      );
    });

    test('waveformColor picks the color for the meter state', () {
      expect(
        theme.waveformColor(LooperMeterState.playing),
        const Color(0xFF4CDA4A),
      );
      expect(
        theme.waveformColor(LooperMeterState.recording),
        const Color(0xFFFF1744),
      );
      // A state the table omits resolves to transparent, matching the
      // meter/indicator tables rather than silently substituting an accent.
      expect(
        theme.waveformColor(LooperMeterState.muted),
        Colors.transparent,
      );
    });

    test('indicatorColor resolves to transparent when the table omits it', () {
      const sparse = LooperTheme(
        tileBackground: Color(0xFF111111),
        tileBorder: Color(0xFF222222),
        waveformColors: {},
        waveformBackground: Color(0xFF000000),
        recordColor: Color(0xFFFF1744),
        fxColor: Color(0xFF3B82F6),
        recordMeterColors: {},
        muteMeterColors: {},
        indicatorColors: {},
        toolbarIconColor: Color(0xFFB0B3BC),
      );
      expect(sparse.indicatorColor(TrackIndicator.play), Colors.transparent);
    });

    test('copyWith overrides only the given fields', () {
      final updated = theme.copyWith(recordColor: const Color(0xFFABCDEF));
      expect(updated.recordColor, const Color(0xFFABCDEF));
      expect(updated.waveformColors, theme.waveformColors);
      expect(updated.recordMeterColors, theme.recordMeterColors);
      expect(updated.muteMeterColors, theme.muteMeterColors);
      expect(updated.indicatorColors, theme.indicatorColors);
    });

    test('copyWith replaces indicatorColors when given', () {
      final updated = theme.copyWith(
        indicatorColors: const {TrackIndicator.idle: Color(0xFF010203)},
      );
      expect(
        updated.indicatorColor(TrackIndicator.idle),
        const Color(0xFF010203),
      );
    });

    test('lerp interpolates toward the other theme', () {
      final other = theme.copyWith(recordColor: const Color(0xFFFFFFFF));
      final mid = theme.lerp(other, 1);
      expect(mid.recordColor, const Color(0xFFFFFFFF));
    });

    test('lerp carries waveformColors toward the other theme', () {
      const white = Color(0xFFFFFFFF);
      final other = theme.copyWith(
        waveformColors: const {
          LooperMeterState.playing: white,
          LooperMeterState.recording: white,
        },
      );
      final end = theme.lerp(other, 1);
      expect(end.waveformColor(LooperMeterState.playing), white);
      expect(end.waveformColor(LooperMeterState.recording), white);
    });

    test('copyWith replaces waveformColors when given', () {
      final updated = theme.copyWith(
        waveformColors: const {LooperMeterState.muted: Color(0xFF010203)},
      );
      expect(
        updated.waveformColor(LooperMeterState.muted),
        const Color(0xFF010203),
      );
      // Replacing the table drops the entries it does not restate — the field
      // is one table, not a per-state merge.
      expect(
        updated.waveformColor(LooperMeterState.playing),
        Colors.transparent,
      );
    });

    test('lerp carries indicatorColors toward the other theme', () {
      final other = theme.copyWith(
        indicatorColors: const {
          TrackIndicator.idle: Color(0xFFFFFFFF),
          TrackIndicator.play: Color(0xFFFFFFFF),
          TrackIndicator.record: Color(0xFFFFFFFF),
        },
      );
      final end = theme.lerp(other, 1);
      const white = Color(0xFFFFFFFF);
      expect(end.indicatorColor(TrackIndicator.idle), white);
      expect(end.indicatorColor(TrackIndicator.play), white);
      expect(end.indicatorColor(TrackIndicator.record), white);
    });

    test('lerp with a non-LooperTheme returns this', () {
      expect(theme.lerp(null, 0.5), same(theme));
    });
  });

  group('LooperMeterState.of', () {
    test('muted wins over the underlying track state', () {
      expect(
        LooperMeterState.of(TrackState.playing, muted: true),
        LooperMeterState.muted,
      );
      expect(
        LooperMeterState.of(TrackState.recording, muted: true),
        LooperMeterState.muted,
      );
    });

    test('maps each track state when not muted', () {
      expect(
        LooperMeterState.of(TrackState.empty, muted: false),
        LooperMeterState.empty,
      );
      expect(
        LooperMeterState.of(TrackState.recording, muted: false),
        LooperMeterState.recording,
      );
      expect(
        LooperMeterState.of(TrackState.overdubbing, muted: false),
        LooperMeterState.overdubbing,
      );
      expect(
        LooperMeterState.of(TrackState.playing, muted: false),
        LooperMeterState.playing,
      );
      expect(
        LooperMeterState.of(TrackState.stopped, muted: false),
        LooperMeterState.stopped,
      );
    });
  });

  group('TrackIndicator.of', () {
    test('muted reads as idle regardless of state, selection, or mode', () {
      for (final state in TrackState.values) {
        expect(
          TrackIndicator.of(
            state,
            muted: true,
            hasContent: true,
            selected: true,
            mode: InteractionMode.record,
          ),
          TrackIndicator.idle,
        );
      }
    });

    test('live transport beats the armed derivation', () {
      // Recording/overdubbing -> record, even when unselected in mute mode.
      expect(
        TrackIndicator.of(
          TrackState.recording,
          muted: false,
          hasContent: false,
          selected: false,
          mode: InteractionMode.mute,
        ),
        TrackIndicator.record,
      );
      expect(
        TrackIndicator.of(
          TrackState.overdubbing,
          muted: false,
          hasContent: true,
          selected: false,
          mode: InteractionMode.mute,
        ),
        TrackIndicator.record,
      );
      // Playing -> play, even when selected in record mode.
      expect(
        TrackIndicator.of(
          TrackState.playing,
          muted: false,
          hasContent: true,
          selected: true,
          mode: InteractionMode.record,
        ),
        TrackIndicator.play,
      );
    });

    test('a stopped track that holds a loop is armed to play (green)', () {
      // Regardless of selection or mode — it will sound on the next play-all,
      // so the indicator stays lit after a stop rather than going dark.
      for (final selected in [true, false]) {
        for (final mode in [InteractionMode.mute, InteractionMode.record]) {
          expect(
            TrackIndicator.of(
              TrackState.stopped,
              muted: false,
              hasContent: true,
              selected: selected,
              mode: mode,
            ),
            TrackIndicator.play,
          );
        }
      }
    });

    test('empty/contentless + selected arms by mode', () {
      // Empty is always contentless; a stopped track with no loop behaves the
      // same (e.g. after a clear). Selected -> arm by mode.
      for (final state in [TrackState.empty, TrackState.stopped]) {
        expect(
          TrackIndicator.of(
            state,
            muted: false,
            hasContent: false,
            selected: true,
            mode: InteractionMode.record,
          ),
          TrackIndicator.record,
          reason: 'record mode arms red',
        );
        expect(
          TrackIndicator.of(
            state,
            muted: false,
            hasContent: false,
            selected: true,
            mode: InteractionMode.mute,
          ),
          TrackIndicator.play,
          reason: 'mute mode arms green',
        );
        expect(
          TrackIndicator.of(
            state,
            muted: false,
            hasContent: false,
            selected: true,
            mode: InteractionMode.fx,
          ),
          TrackIndicator.play,
          reason: 'FX mode starts no take, so the cursor must not read red',
        );
      }
    });

    test('empty/contentless + unselected is idle in either mode', () {
      for (final state in [TrackState.empty, TrackState.stopped]) {
        for (final mode in [InteractionMode.mute, InteractionMode.record]) {
          expect(
            TrackIndicator.of(
              state,
              muted: false,
              hasContent: false,
              selected: false,
              mode: mode,
            ),
            TrackIndicator.idle,
          );
        }
      }
    });
  });

  test('AppTheme maps every meter state in both record and mute modes', () {
    final theme = AppTheme.neon.extension<LooperTheme>()!;
    for (final state in LooperMeterState.values) {
      expect(theme.recordMeterColors[state], isNotNull);
      expect(theme.muteMeterColors[state], isNotNull);
    }
    expect(AppTheme.neon.useMaterial3, isTrue);
  });

  test('both palettes map every waveform state', () {
    // Exit criterion for #499 stage 3b: no state may fall back to the
    // accessor's transparent default, in either variant — a waveform that
    // vanishes in one transport state is worse than the single cyan it
    // replaced.
    for (final data in [AppTheme.neon, AppTheme.highContrast]) {
      final theme = data.extension<LooperTheme>()!;
      for (final state in LooperMeterState.values) {
        expect(
          theme.waveformColors[state],
          isNotNull,
          reason: 'waveform state $state is unmapped',
        );
        expect(theme.waveformColor(state), isNot(Colors.transparent));
      }
    }
  });

  test('the waveform speaks the same legend as the meters', () {
    // The point of the change: the waveform is not its own accent, it repeats
    // the stage colours the meters already use. Assert the relationship rather
    // than the hexes, so a palette migration flows through untouched.
    for (final data in [AppTheme.neon, AppTheme.highContrast]) {
      final theme = data.extension<LooperTheme>()!;
      // The signal-bearing states come straight from the meter table. The
      // quiet ones deliberately do not: the meter paints stopped and muted the
      // same plain white and hides `empty` in a dim groove, while the waveform
      // dims that trio apart by alpha (see below).
      for (final state in [
        LooperMeterState.recording,
        LooperMeterState.overdubbing,
        LooperMeterState.playing,
      ]) {
        expect(
          theme.waveformColor(state),
          theme.meterColor(state, mode: InteractionMode.mute),
          reason: '$state must reuse the meter colour, not a waveform-only one',
        );
      }
      // Recording and playing must not collapse into one another, or the
      // legend says nothing.
      expect(
        theme.waveformColor(LooperMeterState.recording),
        isNot(theme.waveformColor(LooperMeterState.playing)),
      );
      // An empty cursor track reads exactly as a stopped one: both mean "not
      // playing", which is the only thing this surface can honestly say about
      // a track while it draws the whole mix. It must NOT borrow the meter's
      // dim empty groove — that would black out the mix whenever the cursor
      // sits on a fresh track.
      expect(
        theme.waveformColor(LooperMeterState.empty),
        theme.waveformColor(LooperMeterState.stopped),
      );
      expect(
        theme.waveformColor(LooperMeterState.empty),
        isNot(
          theme.meterColor(LooperMeterState.empty, mode: InteractionMode.mute),
        ),
      );
    }
  });

  test('both palettes map every indicator state, idle distinct from tile', () {
    for (final data in [AppTheme.neon, AppTheme.highContrast]) {
      final theme = data.extension<LooperTheme>()!;
      for (final indicator in TrackIndicator.values) {
        expect(theme.indicatorColors[indicator], isNotNull);
      }
      // The idle tone must be distinguishable from the tile surface, or the
      // strip vanishes on inactive tiles.
      expect(
        theme.indicatorColor(TrackIndicator.idle),
        isNot(theme.tileBackground),
      );
    }
  });
}
