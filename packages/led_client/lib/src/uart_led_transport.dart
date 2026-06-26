// The real UART link to the WS2812 driver MCU runs only on a Raspberry Pi (a
// real serial device + a flashed RP2040). It cannot be exercised headless in
// CI, so — like midi_client's native_library.dart and gpio_client's
// lib_gpiod_bindings.dart — it is excluded from coverage. The testable logic
// lives in LedRepository behind the LedTransport interface; this file is its
// on-device backend and is UNVERIFIED on hardware (see firmware/led_driver).
//
// coverage:ignore-file
//
// The C/Dart signature pairs below are each used once (in their matching
// lookupFunction call); that pairing is the FFI idiom.
// ignore_for_file: avoid_private_typedef_functions
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:led_client/src/led_frame.dart';
import 'package:led_client/src/led_transport.dart';

typedef _OpenC = Int Function(Pointer<Utf8>, Int);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _CloseC = Int Function(Int);
typedef _CloseDart = int Function(int);
typedef _ReadC = IntPtr Function(Int, Pointer<Uint8>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Uint8>, int);
typedef _WriteC = IntPtr Function(Int, Pointer<Uint8>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Uint8>, int);
typedef _TcAttrC = Int Function(Int, Pointer<Uint8>);
typedef _TcGetAttrDart = int Function(int, Pointer<Uint8>);
typedef _TcSetAttrC = Int Function(Int, Int, Pointer<Uint8>);
typedef _TcSetAttrDart = int Function(int, int, Pointer<Uint8>);
typedef _CfMakeRawC = Void Function(Pointer<Uint8>);
typedef _CfMakeRawDart = void Function(Pointer<Uint8>);
typedef _CfSetSpeedC = Int Function(Pointer<Uint8>, UnsignedInt);
typedef _CfSetSpeedDart = int Function(Pointer<Uint8>, int);

/// The real UART [LedTransport] for a Raspberry Pi, talking 115200 8N1 to the
/// RP2040 WS2812 driver over the serial pins (default `/dev/serial0`).
class UartLedTransport implements LedTransport {
  /// Creates a [UartLedTransport] for [devicePath].
  UartLedTransport({this.devicePath = '/dev/serial0'})
    : _lib = DynamicLibrary.process();

  /// `struct termios` is 60 bytes on Linux; over-allocate for safety.
  static const int _termiosSize = 64;
  static const int _b115200 = 0x1002; // Linux baud constant.
  static const int _oRdwr = 0x2;
  static const int _oNoctty = 0x100;
  static const int _oNonblock = 0x800;
  static const int _tcsanow = 0x0;

  /// The serial device path.
  final String devicePath;

  final DynamicLibrary _lib;
  int _fd = -1;

  late final _OpenDart _open = _lib.lookupFunction<_OpenC, _OpenDart>('open');
  late final _CloseDart _close = _lib.lookupFunction<_CloseC, _CloseDart>(
    'close',
  );
  late final _ReadDart _read = _lib.lookupFunction<_ReadC, _ReadDart>('read');
  late final _WriteDart _write = _lib.lookupFunction<_WriteC, _WriteDart>(
    'write',
  );
  late final _TcGetAttrDart _tcgetattr = _lib
      .lookupFunction<_TcAttrC, _TcGetAttrDart>('tcgetattr');
  late final _TcSetAttrDart _tcsetattr = _lib
      .lookupFunction<_TcSetAttrC, _TcSetAttrDart>('tcsetattr');
  late final _CfMakeRawDart _cfmakeraw = _lib
      .lookupFunction<_CfMakeRawC, _CfMakeRawDart>('cfmakeraw');
  late final _CfSetSpeedDart _cfsetispeed = _lib
      .lookupFunction<_CfSetSpeedC, _CfSetSpeedDart>('cfsetispeed');
  late final _CfSetSpeedDart _cfsetospeed = _lib
      .lookupFunction<_CfSetSpeedC, _CfSetSpeedDart>('cfsetospeed');

  @override
  void open() {
    if (_fd >= 0) return;
    final pathPtr = devicePath.toNativeUtf8();
    final termios = calloc<Uint8>(_termiosSize);
    try {
      _fd = _open(pathPtr, _oRdwr | _oNoctty | _oNonblock);
      if (_fd < 0) return;
      // Raw 115200 8N1.
      _tcgetattr(_fd, termios);
      _cfmakeraw(termios);
      _cfsetispeed(termios, _b115200);
      _cfsetospeed(termios, _b115200);
      _tcsetattr(_fd, _tcsanow, termios);
    } finally {
      calloc
        ..free(pathPtr)
        ..free(termios);
    }
  }

  @override
  void send(Uint8List frame) {
    if (_fd < 0) return;
    final buf = calloc<Uint8>(frame.length);
    try {
      buf.asTypedList(frame.length).setAll(0, frame);
      _write(_fd, buf, frame.length);
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}) async {
    if (_fd < 0) return false;
    send(LedFrame.pingBytes());
    final deadline = DateTime.now().add(timeout);
    final buf = calloc<Uint8>(16);
    try {
      while (DateTime.now().isBefore(deadline)) {
        final n = _read(_fd, buf, 16);
        if (n > 0) {
          final bytes = buf.asTypedList(n);
          if (bytes.contains(LedFrame.typeAck)) return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return false;
    } finally {
      calloc.free(buf);
    }
  }

  @override
  void close() {
    if (_fd < 0) return;
    _close(_fd);
    _fd = -1;
  }
}
