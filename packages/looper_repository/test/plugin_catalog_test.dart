import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy_engine/loopy_engine.dart' as engine;

import 'helpers/fake_audio_engine.dart';

void main() {
  group('PluginCatalog', () {
    late FakeAudioEngine fake;

    const vst3 = engine.PluginDescriptor(
      id: 'TUID-1',
      name: 'Reverb',
      vendor: 'Acme',
      path: '/plugins/Reverb.vst3',
      format: engine.PluginFormat.vst3,
      version: 0x00010200,
    );
    const clap = engine.PluginDescriptor(
      id: 'com.acme.delay',
      name: 'Delay',
      vendor: 'Acme',
      path: '/plugins/Delay.clap',
      format: engine.PluginFormat.clap,
      version: 0x00000300,
    );

    // Deterministic fake file stats keyed by path.
    final stats = <String, PluginFileStat>{
      '/plugins/Reverb.vst3': (mtimeMs: 1000, sizeBytes: 2048),
      '/plugins/Delay.clap': (mtimeMs: 2000, sizeBytes: 4096),
    };

    PluginCatalog buildCatalog({String appVersion = '1.0.0'}) => PluginCatalog(
      engine: fake,
      appVersion: appVersion,
      pollInterval: const Duration(milliseconds: 1),
      statFile: (path) => stats[path],
    );

    setUp(() {
      fake = FakeAudioEngine()..pluginScanResults = const [vst3, clap];
    });

    test('scan maps engine descriptors into domain descriptors', () async {
      final catalog = buildCatalog();
      final result = await catalog.scan();

      expect(result, hasLength(2));
      expect(result.first.id, 'TUID-1');
      expect(result.first.format, PluginFormat.vst3);
      expect(result.last.format, PluginFormat.clap);
      expect(catalog.descriptors, result);
      expect(catalog.isScanning, isFalse);
      expect(fake.calls, contains('scanBegin'));
      catalog.dispose();
    });

    test('progress stream reports a finished scan', () async {
      final catalog = buildCatalog();
      final progressEvents = <PluginScanProgress>[];
      final sub = catalog.progressStream.listen(progressEvents.add);

      await catalog.scan();
      await Future<void>.delayed(Duration.zero);

      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.done, isTrue);
      expect(progressEvents.last.found, 2);
      await sub.cancel();
      catalog.dispose();
    });

    test('an empty scan yields a clean empty state', () async {
      fake.pluginScanResults = const [];
      final catalog = buildCatalog();
      final result = await catalog.scan();

      expect(result, isEmpty);
      expect(catalog.descriptors, isEmpty);
      expect(catalog.availablePlugins, isEmpty);
      expect(catalog.cache.keys, isEmpty);
      catalog.dispose();
    });

    test('availablePlugins filters out failed entries', () async {
      fake.pluginScanResults = const [
        vst3,
        engine.PluginDescriptor(
          id: '', // failed
          name: 'broken.clap',
          vendor: '',
          path: '/plugins/broken.clap',
          format: engine.PluginFormat.clap,
          version: 0,
        ),
      ];
      final catalog = buildCatalog();
      await catalog.scan();

      expect(catalog.descriptors, hasLength(2));
      expect(catalog.availablePlugins, hasLength(1));
      expect(catalog.availablePlugins.single.id, 'TUID-1');
      catalog.dispose();
    });

    test('cancel keeps results found so far and stops scanning', () async {
      final catalog = buildCatalog();
      // Hold the scan open: poll reports not-done so the timer keeps polling.
      fake.scanProgressOverride = const engine.PluginScanProgress(
        done: false,
        found: 0,
        scanned: 0,
        total: 2,
      );
      final future = catalog.scan();
      expect(catalog.isScanning, isTrue);

      catalog.cancel();
      await future;

      expect(catalog.isScanning, isFalse);
      expect(catalog.progress.done, isTrue);
      expect(fake.calls, contains('scanCancel'));
      catalog.dispose();
    });

    test('a begin failure completes with the prior descriptors', () async {
      // Seed a successful scan, then fail a subsequent begin.
      final catalog = buildCatalog();
      await catalog.scan();
      expect(catalog.descriptors, hasLength(2));

      fake.scanBeginResult = EngineResult.alreadyRunning;
      final result = await catalog.scan();

      expect(result, hasLength(2)); // kept the prior results, did not throw
      expect(catalog.isScanning, isFalse);
      catalog.dispose();
    });

    test('cache is keyed by the scanned files and validates clean', () async {
      final catalog = buildCatalog();
      await catalog.scan();

      expect(catalog.cache.appVersion, '1.0.0');
      expect(catalog.cache.keys, hasLength(2));
      // The cache is valid against the same file keys it was built from.
      expect(
        catalog.cache.isValidFor('1.0.0', catalog.cache.keys),
        isTrue,
      );
      catalog.dispose();
    });
  });

  group('PluginCatalogCache.isValidFor', () {
    const key = PluginCacheKey(path: '/a', mtimeMs: 1, sizeBytes: 10);
    const cache = PluginCatalogCache(
      appVersion: '1.0.0',
      descriptors: [],
      keys: [key],
    );

    test('valid when app version and keys are unchanged', () {
      expect(cache.isValidFor('1.0.0', const [key]), isTrue);
    });

    test('invalid on an app-version bump', () {
      expect(cache.isValidFor('1.0.1', const [key]), isFalse);
    });

    test('invalid when a file mtime changes', () {
      const changed = PluginCacheKey(path: '/a', mtimeMs: 2, sizeBytes: 10);
      expect(cache.isValidFor('1.0.0', const [changed]), isFalse);
    });

    test('invalid when a file size changes', () {
      const changed = PluginCacheKey(path: '/a', mtimeMs: 1, sizeBytes: 11);
      expect(cache.isValidFor('1.0.0', const [changed]), isFalse);
    });

    test('invalid when a new plugin file appears', () {
      const extra = PluginCacheKey(path: '/b', mtimeMs: 3, sizeBytes: 30);
      expect(cache.isValidFor('1.0.0', const [key, extra]), isFalse);
    });

    test('invalid when a plugin file disappears', () {
      expect(cache.isValidFor('1.0.0', const []), isFalse);
    });
  });
}
