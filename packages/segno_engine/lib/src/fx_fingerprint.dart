import 'dart:typed_data';

/// The FNV-1a primitives for the effect-chain fingerprint.
///
/// A fingerprint is an order-sensitive 64-bit hash of a chain's entries — each
/// entry's type code, plus (for a built-in) its parameter float-bits. It is a
/// DIVERGENCE-DETECTION tool: the native engine hashes its published chain
/// (`le_engine_lane_fx_fingerprint`) and the Dart repository hashes its cache
/// with the identical math, so a mismatch flags a cache-vs-engine drift without
/// the engine ever narrating the chain back.
///
/// This mirrors the C `le_fx_chain_fingerprint` exactly: same offset basis,
/// same prime, same little-endian byte folding, and float parameters folded as
/// their float32 bit pattern (the width the engine stores in `a_fx_param`).
/// 64-bit arithmetic wraps modulo 2^64 on the Dart VM, matching the C
/// `uint64_t`; the value is only ever compared for equality, so the signed
/// reinterpretation is immaterial.
abstract final class FxFingerprint {
  /// The FNV-1a 64-bit offset basis (also the hash of an empty chain). Exceeds
  /// 2^63, so it reads as a negative Dart int — the bit pattern is what
  /// matters. VM-only (native FFI comparison); never evaluated under JS.
  // ignore: avoid_js_rounded_ints
  static const int offset = 0xcbf29ce484222325;

  static const int _prime = 0x100000001b3;

  static final Float32List _f32 = Float32List(1);
  static final Uint32List _f32bits = _f32.buffer.asUint32List();

  /// The float32 bit pattern of [value] — the exact width the engine stores in
  /// its `a_fx_param` atomics, so both sides fold identical bits.
  static int floatBits(double value) {
    _f32[0] = value;
    return _f32bits[0];
  }

  /// Folds one 32-bit [value] into the running hash [h], low byte first (so the
  /// fold is endianness-independent, matching the C mirror).
  static int mixU32(int h, int value) {
    var out = h;
    for (var b = 0; b < 4; b++) {
      out = (out ^ ((value >> (8 * b)) & 0xff)) * _prime;
    }
    return out;
  }
}
