import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:loopy/looper/view/signal_graph/signal_graph.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';
import 'package:loopy/session/session.dart';
import 'package:loopy/window/window_chrome.dart';

/// The commands for `TracksView`: the keyboard map plus the dispatch+announce
/// helpers that the toolbar buttons and track tiles share, so the pointer and
/// keyboard paths can never drift in what they dispatch or announce. Created
/// per build over the host's [BuildContext] and used synchronously (in
/// [handleKey] and the button/tile callbacks) while mounted.
///
/// The record/play mode is read from (and toggled on) the shared `PedalCubit`,
/// so `M` here and the pedal's MODE footswitch move the same system state.
class TracksCommands {
  /// Creates commands bound to [context].
  const TracksCommands(this.context);

  /// The host view's build context (blocs, l10n, and semantics are read here).
  final BuildContext context;

  /// Whether any track is currently playing, overdubbing, or recording — the
  /// predicate the `Space` handler and the Play/Stop All toggle both read.
  bool anyActive(LooperState state) => state.tracks.any(
    (t) =>
        t.state == TrackState.playing ||
        t.state == TrackState.overdubbing ||
        t.state == TrackState.recording,
  );

  /// Whether any track would actually sound on a play-all: it holds a loop and
  /// is not muted. When false, every loaded track is muted (or there is no
  /// loop at all), so starting playback would be silent — the Play All control
  /// is disabled and the `Space` key is a no-op in that case.
  bool anyPlayable(LooperState state) =>
      state.tracks.any((t) => t.hasContent && !t.muted);

  /// Toggles global transport: stops all when [playing], otherwise plays all,
  /// announcing the result.
  void togglePlayAll({required bool playing}) {
    context.read<LooperBloc>().add(
      playing ? const LooperStopAllPressed() : const LooperPlayAllPressed(),
    );
    _announce(
      playing ? context.l10n.a11yStoppedAll : context.l10n.a11yPlayingAll,
    );
  }

  /// Clears every track and announces it.
  void clearAll() {
    context.read<LooperBloc>().add(const LooperClearAllPressed());
    _announce(context.l10n.a11yAllCleared);
  }

  /// Undoes the latest layer on [channel] (the bloc clears a lone base loop)
  /// and announces it.
  void undo(int channel) {
    context.read<LooperBloc>().add(LooperUndoPressed(channel));
    _announce(context.l10n.a11yUndone);
  }

  /// Redoes the last undone layer on [channel] and announces it.
  void redo(int channel) {
    context.read<LooperBloc>().add(LooperRedoPressed(channel));
    _announce(context.l10n.a11yRedone);
  }

  /// Toggles the system record/play mode (shared with the pedal) and
  /// announces the mode it landed on.
  void toggleMode() {
    final pedal = context.read<PedalCubit>()..toggleMode();
    _announce(
      pedal.state.mode == LooperMode.record
          ? context.l10n.a11yModeRecord
          : context.l10n.a11yModePlay,
    );
  }

  /// Announces a transient state change to assistive tech (WCAG 4.1.3). The
  /// tracks surface is otherwise silent — state lives in colour and meter
  /// fills a screen-reader cannot perceive.
  void _announce(String message) {
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  /// The tracks keyboard map. Plain keys are consumed (so macOS does not
  /// beep) and dispatched to the looper; modifier combos other than undo/redo
  /// pass through to OS / menu shortcuts.
  ///
  /// Both modes: `M` switch mode · `S` settings · `G` signal · `F` fullscreen ·
  /// `Space` play/pause all · `C` clear all · `Cmd/Ctrl+Z` undo · `Cmd/Ctrl+Y`
  /// (or `Shift+Z`) redo.
  /// Record mode: `1`–`8` select · `R` record/overdub · `P` play/pause.
  /// Play mode: `1`–`8` select + mute/unmute.
  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Let Tab / Shift+Tab fall through so keyboard focus can traverse into the
    // interactive track tiles, mode toggle, and bank switch (WCAG 2.1.2 / 2.4.3)
    // — otherwise the catch-all "swallow plain keys" below would trap focus.
    if (key == LogicalKeyboardKey.tab) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final bloc = context.read<LooperBloc>();
    final tracks = context.read<TracksCubit>();
    final mode = context.read<PedalCubit>().state.mode;
    final l10n = context.l10n;
    final selected = tracks.state.selectedChannel;

    if (keyboard.isMetaPressed || keyboard.isControlPressed) {
      if (key == LogicalKeyboardKey.keyZ) {
        if (keyboard.isShiftPressed) {
          redo(selected);
        } else {
          undo(selected);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        redo(selected);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // let OS / menu shortcuts through
    }

    // Common to both modes.
    if (key == LogicalKeyboardKey.keyM) {
      toggleMode();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      unawaited(openLoopySettings());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyG) {
      unawaited(showSignalPage(context));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      unawaited(toggleLoopyFullScreen());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      // Mirror the on-screen toggle: stop when active, otherwise play — but
      // only when something would actually sound. Swallow the key regardless
      // so a blocked play does not beep.
      final active = anyActive(bloc.state);
      if (active || anyPlayable(bloc.state)) {
        togglePlayAll(playing: active);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      clearAll();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB) {
      final nextBank = tracks.state.activeBank == 0 ? 1 : 0;
      // Selecting the other bank's first track moves the cursor and reveals it.
      tracks.select(nextBank * TracksState.tracksPerBank);
      _announce(l10n.a11yBankSelected(String.fromCharCode(0x41 + nextBank)));
      return KeyEventResult.handled;
    }
    // `U` undoes the latest overdub layer; on a track that holds only its base
    // loop (nothing to undo) it clears the track instead. The bloc decides.
    if (key == LogicalKeyboardKey.keyU) {
      undo(selected);
      return KeyEventResult.handled;
    }

    // Number keys 1–8 select a track (auto-revealing its bank). In play mode
    // they also toggle mute on that track.
    final digit = _digitOf(key);
    if (digit != null) {
      final channel = digit - 1;
      if (channel <= 7) {
        tracks.select(channel); // moves the cursor and reveals its bank
        if (mode == LooperMode.play) {
          bloc.add(LooperMuteToggled(channel));
        }
      }
      return KeyEventResult.handled;
    }

    // Record-mode actions on the selected track.
    if (mode == LooperMode.record) {
      if (key == LogicalKeyboardKey.keyR) {
        bloc.add(LooperRecordPressed(selected));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyP) {
        final track = bloc.state.tracks.firstWhere(
          (t) => t.channel == selected,
          orElse: () => const Track(),
        );
        final playing =
            track.state == TrackState.playing ||
            track.state == TrackState.overdubbing ||
            track.state == TrackState.recording;
        bloc.add(
          playing ? LooperStopPressed(selected) : LooperPlayPressed(selected),
        );
        _announce(playing ? l10n.a11yStopped : l10n.a11yPlaying);
        return KeyEventResult.handled;
      }
    }

    // Swallow other plain keys so macOS does not beep.
    return KeyEventResult.handled;
  }

  /// Maps a `1`–`8` digit key to its number, or `null`. Digit keys have
  /// sequential key ids (ASCII `'1'`–`'8'`), so a range check avoids a map
  /// keyed on the (non-primitive-equality) [LogicalKeyboardKey].
  int? _digitOf(LogicalKeyboardKey key) {
    final id = key.keyId;
    if (id >= LogicalKeyboardKey.digit1.keyId &&
        id <= LogicalKeyboardKey.digit8.keyId) {
      return id - LogicalKeyboardKey.digit0.keyId;
    }
    return null;
  }
}

/// Shows a transient SnackBar surfacing the last session action's outcome —
/// a localized success line, or a localized, human-readable error for the
/// known refusals (sample-rate mismatch, newer manifest version), falling
/// back to the raw message otherwise. The content is a live region so it is
/// announced to assistive tech as it appears (WCAG 4.1.3). Wired as the
/// `TracksView`'s session [BlocListener].
void showSessionOutcome(BuildContext context, SessionState state) {
  final l10n = context.l10n;
  final message = switch (state.status) {
    SessionStatus.success => switch (state.outcome) {
      SessionOutcome.saved => l10n.sessionSaved,
      SessionOutcome.loaded => l10n.sessionLoaded,
      SessionOutcome.mixdownExported => l10n.mixdownExported,
      SessionOutcome.stemsExported => l10n.stemsExported,
      null => null,
    },
    SessionStatus.failure => switch (state.error) {
      SessionError.sampleRateMismatch => l10n.sessionErrorSampleRate,
      SessionError.unsupportedVersion => l10n.sessionErrorUnsupportedVersion,
      SessionError.unknown ||
      null => l10n.sessionErrorGeneric(state.errorMessage ?? ''),
    },
    SessionStatus.idle || SessionStatus.working => null,
  };
  if (message == null) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        key: const Key('tracks_session_snackbar'),
        content: Semantics(liveRegion: true, child: Text(message)),
      ),
    );
}
