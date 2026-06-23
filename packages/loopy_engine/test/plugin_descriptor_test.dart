import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

void main() {
  group('PluginFormat', () {
    test('fromCode maps the native enum values', () {
      expect(PluginFormat.fromCode(0), PluginFormat.vst3);
      expect(PluginFormat.fromCode(1), PluginFormat.clap);
    });

    test('fromCode falls back to vst3 for unknown codes', () {
      expect(PluginFormat.fromCode(99), PluginFormat.vst3);
      expect(PluginFormat.fromCode(-1), PluginFormat.vst3);
    });

    test('code round-trips through fromCode', () {
      for (final format in PluginFormat.values) {
        expect(PluginFormat.fromCode(format.code), format);
      }
    });
  });

  group('PluginDescriptor', () {
    const descriptor = PluginDescriptor(
      id: 'ABCDEF',
      name: 'Reverb',
      vendor: 'Acme',
      path: '/plugins/Reverb.vst3',
      format: PluginFormat.vst3,
      version: 0x00010200,
    );

    test('value equality and hashCode', () {
      const same = PluginDescriptor(
        id: 'ABCDEF',
        name: 'Reverb',
        vendor: 'Acme',
        path: '/plugins/Reverb.vst3',
        format: PluginFormat.vst3,
        version: 0x00010200,
      );
      expect(descriptor, same);
      expect(descriptor.hashCode, same.hashCode);
    });

    test('a populated id is available', () {
      expect(descriptor.isAvailable, isTrue);
    });

    test('an empty id marks a failed entry', () {
      const failed = PluginDescriptor(
        id: '',
        name: 'Broken.clap',
        vendor: '',
        path: '/plugins/Broken.clap',
        format: PluginFormat.clap,
        version: 0,
      );
      expect(failed.isAvailable, isFalse);
    });
  });

  group('PluginScanProgress', () {
    test('empty is a finished, zeroed scan', () {
      expect(PluginScanProgress.empty.done, isTrue);
      expect(PluginScanProgress.empty.found, 0);
      expect(PluginScanProgress.empty.total, 0);
    });

    test('value equality', () {
      const a = PluginScanProgress(done: false, found: 1, scanned: 2, total: 3);
      const b = PluginScanProgress(done: false, found: 1, scanned: 2, total: 3);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
