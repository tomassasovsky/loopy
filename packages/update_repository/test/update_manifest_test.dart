import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('UpdateManifest.fromJson', () {
    test('parses a well-formed manifest', () {
      final manifest = UpdateManifest.fromJson({
        'version': '0.2.0',
        'bundle': 'loopy-appliance-2.raucb',
        'sha256': 'abc123',
        'channel': 'experimental',
        'size': 131803622,
        'notes': 'wide splash + OTA title',
      });

      expect(manifest, isNotNull);
      expect(manifest!.version, Version.parse('0.2.0'));
      expect(manifest.bundle, 'loopy-appliance-2.raucb');
      expect(manifest.sha256, 'abc123');
      expect(manifest.channel, 'experimental');
      expect(manifest.size, 131803622);
      expect(manifest.notes, 'wide splash + OTA title');
    });

    test('parses a prerelease (experimental) version', () {
      final manifest = UpdateManifest.fromJson({
        'version': '0.2.0-experimental.7',
        'bundle': 'b.raucb',
      });

      expect(manifest!.version, Version.parse('0.2.0-experimental.7'));
    });

    test('tolerates a quoted numeric size field (hand-edited manifest)', () {
      final manifest = UpdateManifest.fromJson({
        'version': '0.3.0',
        'bundle': 'b.raucb',
        'size': '42',
      });

      expect(manifest!.size, 42);
    });

    test('defaults optional fields', () {
      final manifest = UpdateManifest.fromJson({
        'version': '0.1.0',
        'bundle': 'b.raucb',
      });

      expect(manifest!.sha256, '');
      expect(manifest.channel, '');
      expect(manifest.size, 0);
      expect(manifest.notes, '');
    });

    test(
      'returns null when version is missing, non-string, or unparseable',
      () {
        expect(UpdateManifest.fromJson({'bundle': 'b.raucb'}), isNull);
        expect(
          UpdateManifest.fromJson({'version': 1, 'bundle': 'b.raucb'}),
          isNull,
        );
        expect(
          UpdateManifest.fromJson({
            'version': 'not-semver',
            'bundle': 'b.raucb',
          }),
          isNull,
        );
      },
    );

    test('returns null when bundle is missing or empty', () {
      expect(UpdateManifest.fromJson({'version': '0.1.0'}), isNull);
      expect(
        UpdateManifest.fromJson({'version': '0.1.0', 'bundle': ''}),
        isNull,
      );
    });
  });

  group('UpdateManifest equality', () {
    UpdateManifest make() => UpdateManifest(
      version: Version.parse('0.2.0'),
      bundle: 'b.raucb',
      sha256: 'sha',
      channel: 'experimental',
      size: 10,
      notes: 'n',
    );

    test('equal manifests compare equal and share a hashCode', () {
      expect(make(), make());
      expect(make().hashCode, make().hashCode);
    });

    test('differing version breaks equality', () {
      final other = UpdateManifest(
        version: Version.parse('0.3.0'),
        bundle: 'b.raucb',
        sha256: 'sha',
        channel: 'experimental',
        size: 10,
        notes: 'n',
      );
      expect(make(), isNot(other));
    });
  });
}
