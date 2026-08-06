import 'dart:io';

/// Whether this build stands in for appliance-only facts.
///
/// The same switch the radios use (`--dart-define=SEGNO_FAKE_RADIOS=true`):
/// disk usage and console identity come from the appliance image, so on a
/// desktop every one of these reads is either unavailable or meaningless, and
/// the Storage and About faces would have nothing to draw. With this on they
/// answer with a plausible rig, so the faces can be seen and driven off the
/// appliance.
const kFakeConsoleFacts = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// What the disk is being used for, in bytes.
class StorageUsage {
  /// Creates a [StorageUsage].
  const StorageUsage({
    this.sessions = 0,
    this.captures = 0,
    this.plugins = 0,
    this.system = 0,
    this.free = 0,
    this.pluginCount = 0,
    this.known = false,
  });

  /// Sessions and their takes.
  final int sessions;

  /// Exports and stems.
  final int captures;

  /// Installed plugins, and how many there are.
  final int plugins;
  final int pluginCount;

  /// The system image and its standby copy.
  final int system;

  /// What is left.
  final int free;

  /// Whether these figures mean anything. False on a platform that cannot
  /// answer — the face says so rather than drawing zeroes as facts.
  final bool known;
}

/// What this console IS: the identity and versions the About face reports.
class ConsoleFacts {
  /// Creates a [ConsoleFacts].
  const ConsoleFacts({
    this.name = '',
    this.serial = '',
    this.systemImage = '',
    this.panel = '',
  });

  /// The console's model name, empty when this is not one.
  final String name;

  /// Its serial, empty when unknown.
  final String serial;

  /// The OS image it boots, empty when unknown.
  final String systemImage;

  /// The panel it draws on, empty when unknown.
  final String panel;
}

/// Reads the appliance facts, or stands in for them.
abstract interface class ConsoleFactsClient {
  /// What the disk holds.
  Future<StorageUsage> usage();

  /// What this console is.
  Future<ConsoleFacts> facts();

  /// Deletes captures older than [days]. Returns the bytes reclaimed.
  Future<int> deleteCapturesOlderThan(int days);

  /// Whether a USB volume is mounted to export to.
  Future<bool> hasExportTarget();
}

/// The real thing: nothing to report yet.
///
/// Disk accounting and USB export live in the appliance image and are not
/// wired to the app (#530). Rather than guess, this answers "unknown", which
/// the faces are built to show honestly.
class UnsupportedConsoleFactsClient implements ConsoleFactsClient {
  /// Creates an [UnsupportedConsoleFactsClient].
  const UnsupportedConsoleFactsClient();

  @override
  Future<StorageUsage> usage() async => const StorageUsage();

  @override
  Future<ConsoleFacts> facts() async => const ConsoleFacts();

  @override
  Future<int> deleteCapturesOlderThan(int days) async => 0;

  @override
  Future<bool> hasExportTarget() async => false;
}

/// A console that answers — for desktop development.
///
/// The rig the mockups draw, so Storage and About can be seen and driven off
/// the appliance: `SYSTEM / storage`'s figures and `SYSTEM / about`'s
/// identity, down to the numbers.
class FakeConsoleFactsClient implements ConsoleFactsClient {
  /// Creates a [FakeConsoleFactsClient].
  ///
  /// [latency] is how long it pretends to take. The default makes the
  /// loading and the housekeeping visible while developing; tests pass
  /// [Duration.zero], since a widget test's clock is not the wall clock and a
  /// pretend delay would hang it rather than illustrate anything.
  FakeConsoleFactsClient({this.latency = const Duration(milliseconds: 120)});

  /// See the constructor.
  final Duration latency;

  /// Pretends to take [latency], and takes nothing at all when that is zero:
  /// even a zero-duration delay schedules a timer, and a widget test that
  /// awaits one without pumping waits forever.
  Future<void> _pretendToWork([int times = 1]) async {
    if (latency <= Duration.zero) return;
    await Future<void>.delayed(latency * times);
  }

  static const int _gb = 1024 * 1024 * 1024;

  int _captures = (6.2 * _gb).round();

  @override
  Future<StorageUsage> usage() async {
    await _pretendToWork();
    return StorageUsage(
      sessions: (41.6 * _gb).round(),
      captures: _captures,
      plugins: (1.1 * _gb).round(),
      pluginCount: 103,
      system: (4.7 * _gb).round(),
      free: (12.4 * _gb).round(),
      known: true,
    );
  }

  @override
  Future<ConsoleFacts> facts() async => const ConsoleFacts(
    name: 'VAMP 16',
    serial: 'VMP-16-0042',
    systemImage: 'Yocto scarthgap · kernel 6.12-rt',
    panel: '16″ 1920×1080 · touch',
  );

  @override
  Future<int> deleteCapturesOlderThan(int days) async {
    await _pretendToWork(3);
    // Half of them are older than a month in this rig.
    final freed = _captures ~/ 2;
    _captures -= freed;
    return freed;
  }

  @override
  Future<bool> hasExportTarget() async => Platform.isMacOS;
}

/// The client this build gets.
ConsoleFactsClient createConsoleFactsClient() => kFakeConsoleFacts
    ? FakeConsoleFactsClient()
    : const UnsupportedConsoleFactsClient();
