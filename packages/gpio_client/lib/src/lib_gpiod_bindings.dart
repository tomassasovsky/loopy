// The real libgpiod FFI path runs only on a Raspberry Pi (a /dev/gpiochip + the
// libgpiod v2 shared library). It cannot be exercised headless in CI, so — like
// `native_library.dart` in midi_client and the generated FFI bindings — it is
// excluded from coverage. The testable logic lives in `GpioControllerSource`
// behind the `GpioBindings` interface; this file is its on-device backend and
// is UNVERIFIED on hardware (see docs/RUNNING_ON_RPI.md).
//
// coverage:ignore-file
//
// The C/Dart signature pairs below are each used exactly once (in their
// matching lookupFunction call); the rule that flags single-use private
// typedefs does not fit an FFI binding, where the pairing is the idiom.
// ignore_for_file: avoid_private_typedef_functions
import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:gpio_client/src/gpio_bindings.dart';

// --- libgpiod v2 opaque structs -------------------------------------------

final class _GpiodChip extends Opaque {}

final class _GpiodLineSettings extends Opaque {}

final class _GpiodLineConfig extends Opaque {}

final class _GpiodRequestConfig extends Opaque {}

final class _GpiodLineRequest extends Opaque {}

// --- libgpiod v2 enum values (from <gpiod.h>, libgpiod 2.x) ----------------

/// `GPIOD_LINE_DIRECTION_INPUT`.
const int _directionInput = 2;

/// `GPIOD_LINE_BIAS_PULL_UP`.
const int _biasPullUp = 4;

/// `GPIOD_LINE_VALUE_INACTIVE` / `_ACTIVE`; `_ERROR` is `-1`.
const int _valueInactive = 0;

// --- FFI signatures --------------------------------------------------------

typedef _ChipOpenC = Pointer<_GpiodChip> Function(Pointer<Utf8>);
typedef _ChipOpenDart = Pointer<_GpiodChip> Function(Pointer<Utf8>);

typedef _ChipCloseC = Void Function(Pointer<_GpiodChip>);
typedef _ChipCloseDart = void Function(Pointer<_GpiodChip>);

typedef _SettingsNewC = Pointer<_GpiodLineSettings> Function();
typedef _SettingsNewDart = Pointer<_GpiodLineSettings> Function();

typedef _SettingsFreeC = Void Function(Pointer<_GpiodLineSettings>);
typedef _SettingsFreeDart = void Function(Pointer<_GpiodLineSettings>);

typedef _SettingsSetIntC = Int Function(Pointer<_GpiodLineSettings>, Int);
typedef _SettingsSetIntDart = int Function(Pointer<_GpiodLineSettings>, int);

typedef _LineConfigNewC = Pointer<_GpiodLineConfig> Function();
typedef _LineConfigNewDart = Pointer<_GpiodLineConfig> Function();

typedef _LineConfigFreeC = Void Function(Pointer<_GpiodLineConfig>);
typedef _LineConfigFreeDart = void Function(Pointer<_GpiodLineConfig>);

typedef _AddLineSettingsC =
    Int Function(
      Pointer<_GpiodLineConfig>,
      Pointer<UnsignedInt>,
      Size,
      Pointer<_GpiodLineSettings>,
    );
typedef _AddLineSettingsDart =
    int Function(
      Pointer<_GpiodLineConfig>,
      Pointer<UnsignedInt>,
      int,
      Pointer<_GpiodLineSettings>,
    );

typedef _ReqConfigNewC = Pointer<_GpiodRequestConfig> Function();
typedef _ReqConfigNewDart = Pointer<_GpiodRequestConfig> Function();

typedef _ReqConfigFreeC = Void Function(Pointer<_GpiodRequestConfig>);
typedef _ReqConfigFreeDart = void Function(Pointer<_GpiodRequestConfig>);

typedef _ReqConfigSetConsumerC =
    Void Function(
      Pointer<_GpiodRequestConfig>,
      Pointer<Utf8>,
    );
typedef _ReqConfigSetConsumerDart =
    void Function(
      Pointer<_GpiodRequestConfig>,
      Pointer<Utf8>,
    );

typedef _RequestLinesC =
    Pointer<_GpiodLineRequest> Function(
      Pointer<_GpiodChip>,
      Pointer<_GpiodRequestConfig>,
      Pointer<_GpiodLineConfig>,
    );
typedef _RequestLinesDart =
    Pointer<_GpiodLineRequest> Function(
      Pointer<_GpiodChip>,
      Pointer<_GpiodRequestConfig>,
      Pointer<_GpiodLineConfig>,
    );

typedef _RequestReleaseC = Void Function(Pointer<_GpiodLineRequest>);
typedef _RequestReleaseDart = void Function(Pointer<_GpiodLineRequest>);

typedef _GetValueC = Int Function(Pointer<_GpiodLineRequest>, UnsignedInt);
typedef _GetValueDart = int Function(Pointer<_GpiodLineRequest>, int);

/// Thrown when a libgpiod request cannot be set up.
class GpioException implements Exception {
  /// Creates a [GpioException].
  const GpioException(this.message);

  /// A human-readable description.
  final String message;

  @override
  String toString() => 'GpioException: $message';
}

/// The real libgpiod v2 backend for [GpioBindings].
///
/// Requests the footswitch lines as pull-up inputs, then polls their values on
/// a short timer and reports changes as edges. Polling (rather than libgpiod's
/// blocking edge-wait) keeps the whole backend on the main isolate with no C
/// glue or worker thread; the ≤poll-interval latency is immaterial for a
/// foot-stomped switch and the leading-edge debounce lives in the source.
class LibGpiodBindings implements GpioBindings {
  /// Opens the platform libgpiod library.
  LibGpiodBindings({String chipPath = '/dev/gpiochip0'})
    : _chipPath = chipPath,
      _lib = _openLibGpiod();

  /// How often the input lines are sampled for changes.
  static const Duration _pollInterval = Duration(milliseconds: 5);

  final String _chipPath;
  final DynamicLibrary _lib;
  final Stopwatch _clock = Stopwatch()..start();

  Pointer<_GpiodChip> _chip = nullptr;
  Pointer<_GpiodLineRequest> _request = nullptr;
  Timer? _poll;
  GpioEdgeCallback? _onEdge;
  List<int> _lines = const [];
  late List<int> _lastLevels;

  late final _ChipOpenDart _chipOpen = _lib
      .lookupFunction<_ChipOpenC, _ChipOpenDart>('gpiod_chip_open');
  late final _ChipCloseDart _chipClose = _lib
      .lookupFunction<_ChipCloseC, _ChipCloseDart>('gpiod_chip_close');
  late final _SettingsNewDart _settingsNew = _lib
      .lookupFunction<_SettingsNewC, _SettingsNewDart>(
        'gpiod_line_settings_new',
      );
  late final _SettingsFreeDart _settingsFree = _lib
      .lookupFunction<_SettingsFreeC, _SettingsFreeDart>(
        'gpiod_line_settings_free',
      );
  late final _SettingsSetIntDart _setDirection = _lib
      .lookupFunction<_SettingsSetIntC, _SettingsSetIntDart>(
        'gpiod_line_settings_set_direction',
      );
  late final _SettingsSetIntDart _setBias = _lib
      .lookupFunction<_SettingsSetIntC, _SettingsSetIntDart>(
        'gpiod_line_settings_set_bias',
      );
  late final _LineConfigNewDart _lineConfigNew = _lib
      .lookupFunction<_LineConfigNewC, _LineConfigNewDart>(
        'gpiod_line_config_new',
      );
  late final _LineConfigFreeDart _lineConfigFree = _lib
      .lookupFunction<_LineConfigFreeC, _LineConfigFreeDart>(
        'gpiod_line_config_free',
      );
  late final _AddLineSettingsDart _addLineSettings = _lib
      .lookupFunction<_AddLineSettingsC, _AddLineSettingsDart>(
        'gpiod_line_config_add_line_settings',
      );
  late final _ReqConfigNewDart _reqConfigNew = _lib
      .lookupFunction<_ReqConfigNewC, _ReqConfigNewDart>(
        'gpiod_request_config_new',
      );
  late final _ReqConfigFreeDart _reqConfigFree = _lib
      .lookupFunction<_ReqConfigFreeC, _ReqConfigFreeDart>(
        'gpiod_request_config_free',
      );
  late final _ReqConfigSetConsumerDart _setConsumer = _lib
      .lookupFunction<_ReqConfigSetConsumerC, _ReqConfigSetConsumerDart>(
        'gpiod_request_config_set_consumer',
      );
  late final _RequestLinesDart _requestLines = _lib
      .lookupFunction<_RequestLinesC, _RequestLinesDart>(
        'gpiod_chip_request_lines',
      );
  late final _RequestReleaseDart _requestRelease = _lib
      .lookupFunction<_RequestReleaseC, _RequestReleaseDart>(
        'gpiod_line_request_release',
      );
  late final _GetValueDart _getValue = _lib
      .lookupFunction<_GetValueC, _GetValueDart>(
        'gpiod_line_request_get_value',
      );

  static DynamicLibrary _openLibGpiod() {
    // Pi OS Bookworm ships libgpiod 2.x as libgpiod.so.3; fall back to the
    // unversioned name when the -dev package is installed.
    for (final name in const ['libgpiod.so.3', 'libgpiod.so']) {
      try {
        return DynamicLibrary.open(name);
      } on Object {
        continue;
      }
    }
    throw const GpioException('libgpiod shared library not found');
  }

  @override
  void open(List<int> lines, GpioEdgeCallback onEdge) {
    _onEdge = onEdge;
    _lines = List.of(lines);

    final pathPtr = _chipPath.toNativeUtf8();
    final consumerPtr = 'loopy'.toNativeUtf8();
    final offsets = calloc<UnsignedInt>(lines.length);
    final settings = _settingsNew();
    final lineConfig = _lineConfigNew();
    final reqConfig = _reqConfigNew();
    try {
      _chip = _chipOpen(pathPtr);
      if (_chip == nullptr) {
        throw GpioException('could not open gpio chip $_chipPath');
      }
      if (settings == nullptr ||
          lineConfig == nullptr ||
          reqConfig == nullptr) {
        throw const GpioException('libgpiod allocation failed');
      }
      // libgpiod setters return 0 on success / -1 on error; a silently ignored
      // failure here yields lines that never fire, so surface it.
      _check(_setDirection(settings, _directionInput), 'set direction');
      _check(_setBias(settings, _biasPullUp), 'set pull-up bias');
      for (var i = 0; i < lines.length; i++) {
        offsets[i] = lines[i];
      }
      _check(
        _addLineSettings(lineConfig, offsets, lines.length, settings),
        'add line settings',
      );
      _setConsumer(reqConfig, consumerPtr);

      _request = _requestLines(_chip, reqConfig, lineConfig);
      if (_request == nullptr) {
        throw const GpioException('could not request gpio lines');
      }

      // Seed the last-known levels so the first poll reports only real changes.
      _lastLevels = [for (final line in lines) _readLevel(line)];
      _poll = Timer.periodic(_pollInterval, (_) => _sample());
    } finally {
      if (settings != nullptr) _settingsFree(settings);
      if (lineConfig != nullptr) _lineConfigFree(lineConfig);
      if (reqConfig != nullptr) _reqConfigFree(reqConfig);
      calloc
        ..free(offsets)
        ..free(pathPtr)
        ..free(consumerPtr);
    }
  }

  static void _check(int result, String what) {
    if (result < 0) throw GpioException('libgpiod failed to $what');
  }

  int _readLevel(int line) {
    final value = _getValue(_request, line);
    // Treat a read error (-1) as the idle (pull-up high) level.
    return value < 0 ? 1 : value;
  }

  void _sample() {
    final cb = _onEdge;
    if (cb == null || _request == nullptr) return;
    final tsUs = _clock.elapsedMicroseconds;
    for (var i = 0; i < _lines.length; i++) {
      final level = _readLevel(_lines[i]);
      if (level != _lastLevels[i]) {
        _lastLevels[i] = level;
        cb(_lines[i], level == _valueInactive ? 0 : 1, tsUs);
      }
    }
  }

  @override
  void close() {
    _poll?.cancel();
    _poll = null;
    if (_request != nullptr) {
      _requestRelease(_request);
      _request = nullptr;
    }
  }

  @override
  void dispose() {
    close();
    if (_chip != nullptr) {
      _chipClose(_chip);
      _chip = nullptr;
    }
  }
}
