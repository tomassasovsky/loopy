import 'package:console_facts_client/src/console_facts_client.dart';
import 'package:console_facts_client/src/console_facts_models.dart';

/// The rig the mockups draw, down to the numbers.
///
/// Selected by `--dart-define=SEGNO_FAKE_RADIOS=true`, the define the radios
/// already use. A second flag would mean holding two switches in your head to
/// see one console, and both mean the same thing: *this build is standing in
/// for the appliance.*
///
/// It exists so `SYSTEM / storage` and `SYSTEM / about` can be seen, driven and
/// photographed into goldens from a desktop. The alternative — plumbing
/// nothing and disabling the two tabs — leaves the design unverifiable, and
/// the alternative of default zeroes leaves the app lying.
class FakeConsoleFactsClient implements ConsoleFactsClient {
  /// Creates a [FakeConsoleFactsClient].
  ///
  /// [latency] fakes the appliance's own read time so loading and the
  /// housekeeping action are visible while developing. Tests pass
  /// [Duration.zero], and at zero the methods return **immediately** rather
  /// than awaiting a zero delay: even `Future.delayed(Duration.zero)`
  /// schedules a timer, and a `testWidgets` body that awaits one without
  /// pumping waits for it forever. A fake that is configurable but still
  /// schedules is not fixed.
  FakeConsoleFactsClient({
    this.latency = const Duration(milliseconds: 220),
    bool exportVolumeMounted = true,
  }) : _exportVolume = exportVolumeMounted ? '/media/usb0' : '';

  /// How long each answer pretends to take.
  final Duration latency;

  final String _exportVolume;

  /// Captures younger than this are kept by [deleteCapturesOlderThan] at the
  /// 30-day setting the face offers — so the delete has something left to
  /// report and the re-read has something different to show.
  static const _recentCaptureBytes = 2100000000;

  var _captureBytes = 6200000000;
  var _staleCaptures = 14;

  Future<void> _wait() async {
    if (latency == Duration.zero) return;
    await Future<void>.delayed(latency);
  }

  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() async {
    await _wait();
    return StorageUsage(
      sessionBytes: 41600000000,
      captureBytes: _captureBytes,
      pluginBytes: 1100000000,
      systemBytes: 4700000000,
      freeBytes: 12400000000 + (6200000000 - _captureBytes),
      pluginCount: 103,
    );
  }

  @override
  Future<ConsoleFacts> facts() async {
    await _wait();
    return const ConsoleFacts(
      name: 'VAMP 16',
      serial: 'VMP-16-0042',
      systemImage: 'Yocto scarthgap · kernel 6.12-rt',
      panel: '16″ 1920×1080 · touch',
    );
  }

  @override
  Future<int> deleteCapturesOlderThan(int days) async {
    await _wait();
    final removed = _staleCaptures;
    if (removed == 0) return 0;
    // Mutates its own figures, so the face's re-read reports something the
    // face could not have guessed.
    _staleCaptures = 0;
    _captureBytes = _recentCaptureBytes;
    return removed;
  }

  @override
  Future<String> exportDestination() async {
    await _wait();
    return _exportVolume;
  }

  @override
  Future<void> exportEverything(String destination) => _wait();
}
