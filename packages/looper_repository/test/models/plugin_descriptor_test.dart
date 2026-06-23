import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart';
import 'package:loopy_engine/loopy_engine.dart' as engine;

void main() {
  group('PluginDescriptor (domain)', () {
    test('value equality and props', () {
      const a = PluginDescriptor(
        id: 'x',
        name: 'A',
        vendor: 'V',
        path: '/p',
        format: PluginFormat.vst3,
        version: 0x00010200,
      );
      const b = PluginDescriptor(
        id: 'x',
        name: 'A',
        vendor: 'V',
        path: '/p',
        format: PluginFormat.vst3,
        version: 0x00010200,
      );
      expect(a, b);
    });

    test('isAvailable reflects a non-empty id', () {
      const ok = PluginDescriptor(
        id: 'x',
        name: 'A',
        vendor: '',
        path: '/p',
        format: PluginFormat.clap,
        version: 0,
      );
      const failed = PluginDescriptor(
        id: '',
        name: 'broken.clap',
        vendor: '',
        path: '/p',
        format: PluginFormat.clap,
        version: 0,
      );
      expect(ok.isAvailable, isTrue);
      expect(failed.isAvailable, isFalse);
    });

    test('versionLabel renders packed major.minor.patch', () {
      const d = PluginDescriptor(
        id: 'x',
        name: 'A',
        vendor: '',
        path: '/p',
        format: PluginFormat.vst3,
        version: 0x00010200, // 1.2.0
      );
      expect(d.versionLabel, '1.2.0');
    });
  });

  group('pluginDescriptorFromEngine', () {
    test('maps every field and the format', () {
      const source = engine.PluginDescriptor(
        id: 'TUID',
        name: 'Delay',
        vendor: 'Acme',
        path: '/plugins/Delay.clap',
        format: engine.PluginFormat.clap,
        version: 0x00000300,
      );
      final mapped = pluginDescriptorFromEngine(source);
      expect(mapped.id, 'TUID');
      expect(mapped.name, 'Delay');
      expect(mapped.vendor, 'Acme');
      expect(mapped.path, '/plugins/Delay.clap');
      expect(mapped.format, PluginFormat.clap);
      expect(mapped.version, 0x00000300);
    });

    test('maps both formats', () {
      expect(
        pluginFormatFromEngine(engine.PluginFormat.vst3),
        PluginFormat.vst3,
      );
      expect(
        pluginFormatFromEngine(engine.PluginFormat.clap),
        PluginFormat.clap,
      );
    });
  });
}
