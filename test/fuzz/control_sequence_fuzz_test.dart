@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';
// The effect models come from the looper_repository barrel (the domain types
// setLaneEffects expects); hide the engine-package originals to disambiguate.
import 'package:loopy_engine/loopy_engine.dart'
    hide
        BuiltInEffect,
        EngineConfig,
        PluginEffect,
        TrackEffect,
        TrackEffectType;
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

/// The control-sequence fuzzer: the REAL native engine (device-free pump) +
/// the real LooperRepository, LooperBloc, ControlOverlayCubit, ControlIntents
/// and PedalCubit, driven by seeded random event sequences across every
/// surface — pedal MIDI through the simulator transport (round-tripping the
/// real wire codec), bloc events, cursor moves, mode toggles, engine time
/// (including 0-frame pumps that hit the drain/queued-undo windows), and
/// explicit poll ticks so snapshot-lag races are reachable. After every step
/// the harness settles and checks the control-surface invariant spec
/// (lib/control/invariants.dart).
///
/// On failure: the seed and a shrunk, replayable action list are printed —
/// paste the sequence into the corpus below as a permanent regression test.
///
/// Self-skips when LOOPY_ENGINE_LIB is unset:
///   export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"
///   flutter test --tags fuzz
void main() {
  final lib = Platform.environment['LOOPY_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'LOOPY_ENGINE_LIB not set — run packages/loopy_engine/tool/build_test_lib.sh'
      : null;

  group('corpus (found-bug regressions, replayed every run)', () {
    test('redo after undo-to-empty relights the LED (2026-07-04)', () {
      _inHarness((h, fa) {
        h
          ..run(const [_Tap(PedalButton.recPlay)], fa) // record
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa) // finalize
          ..settle(fa)
          ..run(const [_Tap(PedalButton.mode)], fa) // -> play, auto-arms
          ..settle(fa);
        expect(h.frame.trackLeds[0], PedalTrackLed.green);

        // Undo past the base layer: track empties, LED dark.
        h
          ..run(const [_Tap(PedalButton.undo)], fa)
          ..settle(fa);
        expect(h.looper.tracks[0].state, TrackState.empty);
        expect(h.looper.tracks[0].redoDepth, greaterThan(0));
        expect(h.frame.trackLeds[0], PedalTrackLed.off);

        // Redo: the loop comes back sounding AND green ('sounding-armed-and-
        // green' — the original bug left it dark).
        h
          ..run(const [_LongPressUndo()], fa)
          ..settle(fa);
        expect(h.looper.tracks[0].state, TrackState.playing);
        expect(h.frame.trackLeds[0], PedalTrackLed.green);
      });
    }, skip: skip);

    test('clear-all also wipes undone-to-empty (redo-able) tracks '
        '(2026-07-04)', () {
      _inHarness((h, fa) {
        h
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..settle(fa)
          ..run(const [_Tap(PedalButton.undo)], fa) // to empty, redo alive
          ..settle(fa);
        expect(h.looper.tracks[0].canRedo, isTrue);

        h
          ..run(const [_Tap(PedalButton.clear)], fa)
          ..settle(fa);
        expect(h.looper.tracks[0].canRedo, isFalse); // resurrect path wiped
        expect(h.looper.transport.masterLengthFrames, 0);
      });
    }, skip: skip);

    test('redo-from-empty comes back unmuted and audible (2026-07-04)', () {
      _inHarness((h, fa) {
        h
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..settle(fa)
          ..run(const [_Tap(PedalButton.stop)], fa) // rec-mode stop mutes
          ..settle(fa);
        expect(h.looper.tracks[0].muted, isTrue);

        h
          ..run(const [_Tap(PedalButton.undo)], fa) // to empty (mute kept)
          ..settle(fa)
          ..run(const [_LongPressUndo()], fa) // redo resurrects
          ..settle(fa);
        expect(h.looper.tracks[0].state, TrackState.playing);
        expect(h.looper.tracks[0].muted, isFalse); // never silent-playing
      });
    }, skip: skip);

    test('a fresh record after undo-to-empty redefines the ghost grid '
        '(2026-07-04)', () {
      _inHarness((h, fa) {
        h
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..pumpLoop(fa) // 256 frames
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..settle(fa)
          ..run(const [_Tap(PedalButton.undo)], fa) // to empty; grid kept
          ..settle(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa) // fresh take
          ..run(const [_Pump(400, 0.5)], fa) // LONGER than the dead grid
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..settle(fa);
        // The new loop defines its own length instead of rounding to 256.
        expect(h.looper.transport.masterLengthFrames, 400);
      });
    }, skip: skip);

    test('set then clear a lane chain keeps cache == engine (F6)', () {
      _inHarness((h, fa) {
        h
          ..run(const [
            _SetLaneChain(0, 0, [0, 3]),
          ], fa) // drive, reverb
          ..settle(fa);
        expect(h.fxFingerprintViolation(), isNull);

        h
          ..run(const [_SetLaneChain(0, 0, [])], fa) // clear
          ..settle(fa);
        expect(h.fxFingerprintViolation(), isNull);
        expect(h.repo.laneChainFingerprint(0, 0), FxFingerprint.offset);
      });
    }, skip: skip);

    test('a staged lane chain survives a dry-monitor record with cache == '
        'engine (F4/F6)', () {
      _inHarness((h, fa) {
        // Stage a lane chain, then record a take through a CLEAN monitor: the
        // lane chain must survive (F4) and cache must still equal engine (F6).
        h
          ..run(const [
            _SetLaneChain(0, 0, [1]),
          ], fa) // filter
          ..settle(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa) // record from empty
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa) // finalize
          ..settle(fa);
        expect(h.looper.tracks[0].lanes[0].effects, hasLength(1));
        expect(h.fxFingerprintViolation(), isNull);
      });
    }, skip: skip);

    test('recording through a monitor chain copies it onto the lane, cache == '
        'engine (F3/F6)', () {
      _inHarness((h, fa) {
        // A monitor chain on input 0 is snapshot-copied onto the take's lane on
        // record-from-empty; both the copy and the resulting chain must agree.
        h
          ..run(const [
            _SetMonitorChain(0, [2, 3]),
          ], fa) // delay, reverb
          ..settle(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..settle(fa);
        expect(h.looper.tracks[0].lanes[0].effects, hasLength(2));
        expect(h.fxFingerprintViolation(), isNull);
      });
    }, skip: skip);

    test('clearing a take drops its FX chain so a later dry record does not '
        'inherit it, cache == engine (leftover-from-previous-config)', () {
      _inHarness((h, fa) {
        // Config A: monitor [reverb, delay], record a take onto the lane.
        h
          ..run(const [
            _SetMonitorChain(0, [3, 2]),
          ], fa) // reverb, delay
          ..settle(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..settle(fa);
        expect(h.looper.tracks[0].lanes[0].effects, hasLength(2));

        // Erase the take and go dry (a config change), then re-record from
        // empty: the fresh dry take must NOT resurrect A's chain.
        h
          ..run(const [_Tap(PedalButton.clear)], fa)
          ..run(const [
            _SetMonitorChain(0, []),
          ], fa) // dry monitor
          ..settle(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa)
          ..settle(fa);
        expect(h.looper.tracks[0].lanes[0].effects, isEmpty);
        expect(h.fxFingerprintViolation(), isNull);
      });
    }, skip: skip);

    test('monitor FX set then record-from-empty in the SAME turn (no drain) '
        'still lands on the take, cache == engine (snapshot race)', () {
      _inHarness((h, fa) {
        // The regression: set a monitor chain and record from EMPTY with NO
        // ring drain between the two (the widest race window — the engine used
        // to self-snapshot a not-yet-published monitor count and print a dry
        // take). The repo owns the snapshot now, so the take carries the chain
        // and cache == engine holds after the settle.
        h
          ..run(const [
            _SetMonitorThenRecord(0, 0, [2, 3]),
          ], fa) // delay, reverb
          ..pumpLoop(fa)
          ..run(const [_Tap(PedalButton.recPlay)], fa) // finalize
          ..settle(fa);
        expect(h.looper.tracks[0].lanes[0].effects, hasLength(2));
        expect(h.fxFingerprintViolation(), isNull);
      });
    }, skip: skip);
  });

  test('seeded random sequences hold every invariant', () {
    const seeds = int.fromEnvironment('LOOPY_FUZZ_SEEDS', defaultValue: 12);
    const steps = int.fromEnvironment('LOOPY_FUZZ_STEPS', defaultValue: 120);
    const baseSeed = int.fromEnvironment('LOOPY_FUZZ_BASE', defaultValue: 6407);

    for (var i = 0; i < seeds; i++) {
      final seed = baseSeed + i * 7919;
      final actions = _generate(seed, steps);
      final failure = _replay(actions);
      if (failure == null) continue;

      final shrunk = _shrink(actions);
      final repro = shrunk.map((a) => a.describe()).join(',\n  ');
      fail(
        'seed $seed violated the spec: $failure\n'
        'shrunk repro (${shrunk.length}/${actions.length} steps):\n'
        '[\n  $repro\n]',
      );
    }
  }, skip: skip);
}

// ---------------------------------------------------------------------------
// Harness: the full real stack under FakeAsync-controlled time.
// ---------------------------------------------------------------------------

class _Harness {
  _Harness(FakeAsync fa) {
    engine = PumpedNativeEngine();
    ticker = StreamController<void>.broadcast(sync: true);
    reconnectTicker = StreamController<void>.broadcast(sync: true);
    // A real temp dir rather than '.': `arm()`'s directory creation never
    // actually completes inside this FakeAsync zone today (real dart:io
    // async ops don't run there), so this is defense-in-depth, not a fix for
    // an observed leak — if a MODE long-press ever fires for real in a fuzz
    // sequence, or `arm()` picks up sync file I/O, this is what stands
    // between that and polluting the repo working directory.
    tempDir = Directory.systemTemp.createTempSync('loopy_control_fuzz');
    repo = LooperRepository(
      engine: engine,
      ticker: ticker.stream,
      reconnectTicker: reconnectTicker.stream,
    );
    repo.startEngine(
      const EngineConfig(
        sampleRate: 48000,
        inputChannels: 1,
        outputChannels: 1,
        maxLoopFrames: 48000,
      ),
    );
    final settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = LooperBloc(repository: repo);
    sim = SimulatorPedalTransport(inner: const NoopPedalTransport());
    pedalRepo = PedalRepository(sim);
    performance = PerformanceRepository(
      engine: engine,
      exportsRoot: () async => tempDir.path,
    );
    control = ControlCubit(
      looper: repo,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    cubit = PedalCubit(
      pedal: pedalRepo,
      settings: settings,
      pollInterval: Duration.zero,
    );
    pedalRepo.bind(kSimulatorOutputId); // LED frames round-trip the codec
    settle(fa);
  }

  late final Directory tempDir;
  late final PumpedNativeEngine engine;
  late final StreamController<void> ticker;
  late final StreamController<void> reconnectTicker;
  late final LooperRepository repo;
  late final LooperBloc bloc;
  late final SimulatorPedalTransport sim;
  late final PedalRepository pedalRepo;
  late final PerformanceRepository performance;
  late final ControlCubit control;
  late final PedalCubit cubit;
  final Set<PedalButton> _held = {};

  LooperState get looper => repo.state;
  PedalStateFrame get frame => sim.frame.value;

  ControlContext get context => ControlContext(
    looper: looper,
    overlay: control.state,
    frame: frame,
  );

  /// The FX-state invariant, checked only while the engine is running (a
  /// stopped engine holds a stale published chain the cache legitimately
  /// leads): every lane / monitor's cached chain fingerprint must equal the
  /// published-chain fingerprint. Returns a violation message or null.
  ///
  /// This is the F6 safety net — it catches a wiped lane (F4) and any
  /// cache/engine drift the fuzz alphabet's FX actions (set/clear lane +
  /// monitor chains, record-over) can produce. Session-load leftovers (the F2 /
  /// F2c class) are out of the FakeAsync alphabet's reach — real file I/O can't
  /// run under FakeAsync — and are covered by the dedicated round-trip test
  /// (test/session/session_fx_roundtrip_test.dart), which asserts this same
  /// cache == engine equality after a save → clear → load.
  String? fxFingerprintViolation() {
    if (!looper.transport.isRunning) return null;
    for (var channel = 0; channel < looper.tracks.length; channel++) {
      final lanes = looper.tracks[channel].lanes.length;
      for (var lane = 0; lane < (lanes < 1 ? 1 : lanes); lane++) {
        final cache = repo.laneChainFingerprint(channel, lane);
        final engineFp = engine.laneFxFingerprint(channel: channel, lane: lane);
        if (cache != engineFp) {
          return 'lane ($channel,$lane) cache fp $cache != engine $engineFp';
        }
      }
    }
    for (var input = 0; input < kMaxInputs; input++) {
      final cache = repo.monitorChainFingerprint(input);
      final engineFp = engine.monitorFxFingerprint(input: input);
      if (cache != engineFp) {
        return 'monitor $input cache fp $cache != engine $engineFp';
      }
    }
    return null;
  }

  /// One engine block + one snapshot poll + microtask flush, twice — the
  /// "settled" point the invariant spec is defined over.
  void settle(FakeAsync fa) {
    for (var i = 0; i < 2; i++) {
      engine.pump(frames: 0);
      ticker.add(null);
      fa.flushMicrotasks();
    }
  }

  /// Records one full base loop's worth of input (the corpus default).
  void pumpLoop(FakeAsync fa) => run(const [_Pump(256, 0.5)], fa);

  void run(List<_FuzzAction> actions, FakeAsync fa) {
    for (final action in actions) {
      action.apply(this, fa);
      fa.flushMicrotasks();
    }
  }

  void dispose(FakeAsync fa) {
    unawaited(control.close());
    unawaited(cubit.close());
    unawaited(bloc.close());
    performance.dispose();
    fa.flushMicrotasks();
    unawaited(repo.dispose());
    fa.flushMicrotasks();
    unawaited(ticker.close());
    unawaited(reconnectTicker.close());
    fa.flushMicrotasks();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }
}

void _inHarness(void Function(_Harness h, FakeAsync fa) body) {
  FakeAsync().run((fa) {
    final h = _Harness(fa);
    try {
      body(h, fa);
    } finally {
      h.dispose(fa);
    }
  });
}

// ---------------------------------------------------------------------------
// Actions: the fuzz alphabet. Every action is replayable and printable.
// ---------------------------------------------------------------------------

sealed class _FuzzAction {
  const _FuzzAction();
  void apply(_Harness h, FakeAsync fa);
  String describe();
}

class _Tap extends _FuzzAction {
  const _Tap(this.button);
  final PedalButton button;
  @override
  void apply(_Harness h, FakeAsync fa) {
    h.sim
      ..press(button, down: true)
      ..press(button, down: false);
  }

  @override
  String describe() => '_Tap(PedalButton.${button.name})';
}

class _Hold extends _FuzzAction {
  const _Hold(this.button);
  final PedalButton button;
  @override
  void apply(_Harness h, FakeAsync fa) {
    if (h._held.add(button)) h.sim.press(button, down: true);
  }

  @override
  String describe() => '_Hold(PedalButton.${button.name})';
}

class _Release extends _FuzzAction {
  const _Release(this.button);
  final PedalButton button;
  @override
  void apply(_Harness h, FakeAsync fa) {
    if (h._held.remove(button)) h.sim.press(button, down: false);
  }

  @override
  String describe() => '_Release(PedalButton.${button.name})';
}

class _LongPressUndo extends _FuzzAction {
  const _LongPressUndo();
  @override
  void apply(_Harness h, FakeAsync fa) {
    h.sim.press(PedalButton.undo, down: true);
    fa
      ..elapse(const Duration(milliseconds: 600))
      ..flushMicrotasks();
    h.sim.press(PedalButton.undo, down: false);
  }

  @override
  String describe() => '_LongPressUndo()';
}

class _Encoder extends _FuzzAction {
  const _Encoder(this.delta);
  final int delta;
  @override
  void apply(_Harness h, FakeAsync fa) => h.sim.turn(delta);
  @override
  String describe() => '_Encoder($delta)';
}

class _Bloc extends _FuzzAction {
  const _Bloc(this.kind, this.channel);
  final String kind;
  final int channel;
  @override
  void apply(_Harness h, FakeAsync fa) {
    switch (kind) {
      case 'record':
        h.bloc.add(LooperRecordPressed(channel));
      case 'stop':
        h.bloc.add(LooperStopPressed(channel));
      case 'play':
        h.bloc.add(LooperPlayPressed(channel));
      case 'clear':
        h.bloc.add(LooperClearPressed(channel));
      case 'undo':
        h.bloc.add(LooperUndoPressed(channel));
      case 'redo':
        h.bloc.add(LooperRedoPressed(channel));
      case 'mute':
        h.bloc.add(LooperMuteToggled(channel));
      case 'clearAll':
        // The on-screen clear-all path IS the unified intent now.
        unawaited(h.control.clearAll());
    }
  }

  @override
  String describe() => "_Bloc('$kind', $channel)";
}

class _Select extends _FuzzAction {
  const _Select(this.channel);
  final int channel;
  @override
  void apply(_Harness h, FakeAsync fa) => h.control.selectTrack(channel);
  @override
  String describe() => '_Select($channel)';
}

class _ToggleMode extends _FuzzAction {
  const _ToggleMode();
  @override
  void apply(_Harness h, FakeAsync fa) => h.control.toggleMode();
  @override
  String describe() => '_ToggleMode()';
}

class _Pump extends _FuzzAction {
  const _Pump(this.frames, this.input);
  final int frames;
  final double input;
  @override
  void apply(_Harness h, FakeAsync fa) =>
      h.engine.pump(frames: frames, input: input);
  @override
  String describe() => '_Pump($frames, $input)';
}

class _Tick extends _FuzzAction {
  const _Tick();
  @override
  void apply(_Harness h, FakeAsync fa) => h.ticker.add(null);
  @override
  String describe() => '_Tick()';
}

class _Elapse extends _FuzzAction {
  const _Elapse(this.ms);
  final int ms;
  @override
  void apply(_Harness h, FakeAsync fa) => fa.elapse(Duration(milliseconds: ms));
  @override
  String describe() => '_Elapse($ms)';
}

class _Reconnect extends _FuzzAction {
  const _Reconnect();
  @override
  void apply(_Harness h, FakeAsync fa) => h.cubit.reconnect();
  @override
  String describe() => '_Reconnect()';
}

/// A small palette of built-in types the FX actions draw from (index into
/// [TrackEffectType.values] skipping `none`, which is a bypass, not an entry).
const List<TrackEffectType> _fxPalette = [
  TrackEffectType.drive,
  TrackEffectType.filter,
  TrackEffectType.delay,
  TrackEffectType.reverb,
];

/// Sets lane [lane] of track [channel]'s chain to [types] (empty clears it),
/// straight through the repository — the same call the bloc makes.
class _SetLaneChain extends _FuzzAction {
  const _SetLaneChain(this.channel, this.lane, this.types);
  final int channel;
  final int lane;
  final List<int> types; // indices into _fxPalette

  @override
  void apply(_Harness h, FakeAsync fa) => h.repo.setLaneEffects(
    channel: channel,
    lane: lane,
    effects: [for (final t in types) BuiltInEffect(type: _fxPalette[t])],
  );

  @override
  String describe() => '_SetLaneChain($channel, $lane, $types)';
}

/// Sets monitor input [input]'s chain to [types] (empty clears it).
class _SetMonitorChain extends _FuzzAction {
  const _SetMonitorChain(this.input, this.types);
  final int input;
  final List<int> types;

  @override
  void apply(_Harness h, FakeAsync fa) => h.repo.setMonitorEffects(
    input: input,
    effects: [for (final t in types) BuiltInEffect(type: _fxPalette[t])],
  );

  @override
  String describe() => '_SetMonitorChain($input, $types)';
}

/// Sets monitor input [input]'s chain to [types] AND records track [channel]
/// from empty in the SAME turn — no ring drain between the monitor push and the
/// record snapshot. This is the ordering that exposed the snapshot race: the
/// engine's self-snapshot read a not-yet-published monitor count and printed a
/// dry take. The repository owns the snapshot now, so the take must still carry
/// the chain and cache == engine must hold after the next settle.
class _SetMonitorThenRecord extends _FuzzAction {
  const _SetMonitorThenRecord(this.input, this.channel, this.types);
  final int input;
  final int channel;
  final List<int> types;

  @override
  void apply(_Harness h, FakeAsync fa) {
    h.repo.setMonitorEffects(
      input: input,
      effects: [for (final t in types) BuiltInEffect(type: _fxPalette[t])],
    );
    h.bloc.add(LooperRecordPressed(channel));
  }

  @override
  String describe() => '_SetMonitorThenRecord($input, $channel, $types)';
}

// ---------------------------------------------------------------------------
// Generation, replay, shrinking.
// ---------------------------------------------------------------------------

/// Hand-rolled xorshift PRNG — deterministic across platforms and runs.
class _Rng {
  _Rng(int seed) : _s = seed == 0 ? 0x9E3779B9 : seed;
  int _s;
  int next(int max) {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s % max;
  }
}

List<_FuzzAction> _generate(int seed, int steps) {
  final rng = _Rng(seed);
  const buttons = PedalButton.values;
  final actions = <_FuzzAction>[];
  // A short random chain of palette indices (length 0..3; 0 = clear the chain).
  List<int> types() => [
    for (var k = 0, n = rng.next(4); k < n; k++) rng.next(_fxPalette.length),
  ];
  for (var i = 0; i < steps; i++) {
    final roll = rng.next(100);
    actions.add(switch (roll) {
      < 28 => _Tap(buttons[rng.next(buttons.length)]),
      < 34 => _Hold(buttons[rng.next(buttons.length)]),
      < 40 => _Release(buttons[rng.next(buttons.length)]),
      < 44 => const _LongPressUndo(),
      < 48 => _Encoder(rng.next(17) - 8),
      < 64 => _Bloc(
        const [
          'record',
          'stop',
          'play',
          'clear',
          'undo',
          'redo',
          'mute',
          'clearAll',
        ][rng.next(8)],
        rng.next(8),
      ),
      < 70 => _Select(rng.next(8)),
      < 74 => const _ToggleMode(),
      < 84 => _Pump(const [0, 1, 17, 256, 300][rng.next(5)], 0.5),
      < 88 => const _Tick(),
      < 92 => _Elapse(const [5, 50, 600][rng.next(3)]),
      // FX actions (the F6 alphabet): set/clear a lane or monitor chain, or the
      // race ordering — monitor-then-record with no drain between. Input is
      // pinned to 0 (not randomized like _SetMonitorChain): a track's lane 0
      // records input 0 by default, so only a monitor on input 0 reaches the
      // recorded lane — the ordering under test.
      < 95 => _SetLaneChain(rng.next(4), rng.next(2), types()),
      < 97 => _SetMonitorChain(rng.next(4), types()),
      < 99 => _SetMonitorThenRecord(0, rng.next(4), types()),
      _ => const _Reconnect(),
    });
  }
  return actions;
}

/// Replays [actions] on a fresh harness; returns the first violation message
/// (with its step index) or null when the whole sequence stays clean.
String? _replay(List<_FuzzAction> actions) {
  String? failure;
  FakeAsync().run((fa) {
    final h = _Harness(fa);
    try {
      for (var i = 0; i < actions.length; i++) {
        try {
          actions[i].apply(h, fa);
          fa.flushMicrotasks();
          h.settle(fa);
        } on Object catch (e) {
          // The projection-time debug assert can throw mid-sequence: that IS
          // a spec violation, attributed to this step.
          failure = 'step $i (${actions[i].describe()}): $e';
          return;
        }
        final violations = checkControlInvariants(h.context);
        if (violations.isNotEmpty) {
          failure = 'step $i (${actions[i].describe()}): ${violations.first}';
          return;
        }
        final fx = h.fxFingerprintViolation();
        if (fx != null) {
          failure = 'step $i (${actions[i].describe()}): $fx';
          return;
        }
      }
    } finally {
      try {
        h.dispose(fa);
      } on Object {
        // Teardown after a violation can cascade; the original failure wins.
      }
    }
  });
  return failure;
}

/// Greedy one-pass delta shrink: drop each action once; keep the drop when
/// the sequence still fails. Bounded, simple, good enough for repro output.
List<_FuzzAction> _shrink(List<_FuzzAction> actions) {
  var current = List.of(actions);
  for (var i = current.length - 1; i >= 0; i--) {
    if (current.length <= 1) break;
    final candidate = List.of(current)..removeAt(i);
    if (_replay(candidate) != null) current = candidate;
  }
  return current;
}
