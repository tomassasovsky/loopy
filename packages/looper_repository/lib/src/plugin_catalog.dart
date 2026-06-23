import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart';
import 'package:loopy_engine/loopy_engine.dart' as engine;

/// A file's identity for cache keying: its path plus last-modified time and
/// size. A reinstalled or updated plugin changes its mtime/size, invalidating
/// the cached descriptor for that file (umbrella D-SCAN).
typedef PluginFileStat = ({int mtimeMs, int sizeBytes});

/// One cached file's identity (path + mtime + size). Equality is the whole
/// triple, so any change re-scans that file.
class PluginCacheKey extends Equatable {
  /// Creates a [PluginCacheKey].
  const PluginCacheKey({
    required this.path,
    required this.mtimeMs,
    required this.sizeBytes,
  });

  /// The plugin file/bundle path.
  final String path;

  /// Last-modified time in milliseconds since epoch.
  final int mtimeMs;

  /// File/bundle size in bytes.
  final int sizeBytes;

  @override
  List<Object?> get props => [path, mtimeMs, sizeBytes];
}

/// A cached scan result: the descriptors plus the file keys they were derived
/// from and the app version that produced them. Persisting/restoring this
/// across launches is part 7's concern; here it is the in-memory cache the
/// [PluginCatalog] holds and validates.
class PluginCatalogCache extends Equatable {
  /// Creates a [PluginCatalogCache].
  const PluginCatalogCache({
    required this.appVersion,
    required this.descriptors,
    required this.keys,
  });

  /// An empty cache for [appVersion].
  const PluginCatalogCache.empty(this.appVersion)
    : descriptors = const [],
      keys = const [];

  /// The app version that produced this cache.
  final String appVersion;

  /// The cached descriptors.
  final List<PluginDescriptor> descriptors;

  /// The file keys the descriptors were derived from (one per scanned file).
  final List<PluginCacheKey> keys;

  /// Whether this cache is still valid for [appVersion] given the current file
  /// keys: the app version must match and the set of file keys must be
  /// unchanged (a reinstalled/updated/removed plugin changes its key). A
  /// newly-installed plugin adds a key, so a differing set also invalidates.
  bool isValidFor(String appVersion, List<PluginCacheKey> currentKeys) {
    if (appVersion != this.appVersion) return false;
    if (currentKeys.length != keys.length) return false;
    final mine = keys.toSet();
    return currentKeys.every(mine.contains);
  }

  @override
  List<Object?> get props => [appVersion, descriptors, keys];
}

/// Drives an asynchronous plugin scan over the [engine] and holds the results.
///
/// The native scan runs on its own thread; this catalog polls it on a timer,
/// publishes [progress], and exposes the resulting [descriptors]. Results are
/// cached keyed by each file's (path, mtime, size) and the app version, so a
/// caller can decide whether a re-scan is needed (the cache invalidates on an
/// app-version bump or any plugin file change). A minimal scan-result holder —
/// not a persistence framework (that is part 7).
class PluginCatalog {
  /// Creates a [PluginCatalog] driving [engine].
  ///
  /// [appVersion] keys the cache so an app upgrade forces a fresh scan.
  /// [pollInterval] is how often the running scan is polled. [statFile] reads a
  /// file's (mtime, size) for cache keying; the default stats the real
  /// filesystem and returns `null` for a missing file (injected in tests).
  PluginCatalog({
    required engine.EnginePluginHosting engine,
    required String appVersion,
    Duration pollInterval = const Duration(milliseconds: 100),
    PluginFileStat? Function(String path)? statFile,
  }) : _engine = engine,
       _appVersion = appVersion,
       _pollInterval = pollInterval,
       _statFile = statFile ?? _defaultStat;

  final engine.EnginePluginHosting _engine;
  final String _appVersion;
  final Duration _pollInterval;
  final PluginFileStat? Function(String path) _statFile;

  final _progressController =
      StreamController<engine.PluginScanProgress>.broadcast();

  Timer? _timer;
  Completer<List<PluginDescriptor>>? _scan;
  List<PluginDescriptor> _descriptors = const [];
  PluginCatalogCache _cache = const PluginCatalogCache(
    appVersion: '',
    descriptors: [],
    keys: [],
  );
  engine.PluginScanProgress _progress = engine.PluginScanProgress.empty;

  /// The most recent scan results (cached in memory). Empty until the first
  /// scan completes.
  List<PluginDescriptor> get descriptors => _descriptors;

  /// Only the loadable plugins (failed entries filtered out).
  List<PluginDescriptor> get availablePlugins =>
      _descriptors.where((d) => d.isAvailable).toList();

  /// The latest scan progress.
  engine.PluginScanProgress get progress => _progress;

  /// A stream of scan-progress updates while a scan runs.
  Stream<engine.PluginScanProgress> get progressStream =>
      _progressController.stream;

  /// Whether a scan is currently in progress.
  bool get isScanning => _scan != null;

  /// The current in-memory cache snapshot: the descriptors plus the
  /// (path, mtime, size) file keys they were derived from, keyed to the app
  /// version. Validate it against the current filesystem with
  /// [PluginCatalogCache.isValidFor] to decide whether a re-scan is needed
  /// (persisting it across launches is part 7's concern).
  PluginCatalogCache get cache => _cache;

  /// Starts a scan and completes with the discovered descriptors. If a scan is
  /// already running, returns that in-flight future. Pass [rescan] to ignore
  /// any native cache.
  ///
  /// If the engine refuses to begin a scan (e.g. one is already running on the
  /// native side), this completes immediately with the previously-cached
  /// [descriptors] rather than throwing.
  Future<List<PluginDescriptor>> scan({bool rescan = false}) {
    final existing = _scan;
    if (existing != null) return existing.future;

    final completer = Completer<List<PluginDescriptor>>();
    _scan = completer;

    final result = _engine.scanBegin(rescan: rescan);
    if (!result.isOk) {
      _finish(completer, _descriptors);
      return completer.future;
    }

    _timer = Timer.periodic(_pollInterval, (_) => _poll(completer));
    return completer.future;
  }

  /// Cancels an in-progress scan, keeping whatever was found so far.
  void cancel() {
    if (_scan == null) return;
    _engine.scanCancel();
    final completer = _scan!;
    _publish(_engine.scanPoll(), forceDone: true);
    _harvest();
    _finish(completer, _descriptors);
  }

  void _poll(Completer<List<PluginDescriptor>> completer) {
    final native = _engine.scanPoll();
    _publish(native);
    if (!native.done) return;
    _harvest();
    _finish(completer, _descriptors);
  }

  /// Reads the finished descriptors and rebuilds the cache from their files.
  void _harvest() {
    _descriptors = _engine
        .scanResults()
        .map(pluginDescriptorFromEngine)
        .toList();
    final paths = <String>{for (final d in _descriptors) d.path};
    _cache = PluginCatalogCache(
      appVersion: _appVersion,
      descriptors: _descriptors,
      keys: _keysFor(paths),
    );
  }

  List<PluginCacheKey> _keysFor(Iterable<String> paths) {
    final keys = <PluginCacheKey>[];
    for (final path in paths) {
      final stat = _statFile(path);
      if (stat == null) continue; // missing file: dropped from the key set
      keys.add(
        PluginCacheKey(
          path: path,
          mtimeMs: stat.mtimeMs,
          sizeBytes: stat.sizeBytes,
        ),
      );
    }
    return keys;
  }

  void _publish(engine.PluginScanProgress native, {bool forceDone = false}) {
    _progress = forceDone && !native.done
        ? engine.PluginScanProgress(
            done: true,
            found: native.found,
            scanned: native.scanned,
            total: native.total,
          )
        : native;
    if (!_progressController.isClosed) _progressController.add(_progress);
  }

  void _finish(
    Completer<List<PluginDescriptor>> completer,
    List<PluginDescriptor> result,
  ) {
    _timer?.cancel();
    _timer = null;
    _scan = null;
    if (!completer.isCompleted) completer.complete(result);
  }

  /// Cancels any running scan and releases the progress stream.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_scan != null) _engine.scanCancel();
    _scan = null;
    unawaited(_progressController.close());
  }

  static PluginFileStat? _defaultStat(String path) {
    try {
      final stat = FileStat.statSync(path);
      if (stat.type == FileSystemEntityType.notFound) return null;
      return (
        mtimeMs: stat.modified.millisecondsSinceEpoch,
        sizeBytes: stat.size,
      );
    } on FileSystemException {
      return null;
    }
  }
}
