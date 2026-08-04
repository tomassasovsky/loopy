import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('UpdateManifest.fromJson', () {
    test('parses a well-formed manifest', () {
      final manifest = UpdateManifest.fromJson({
        'version': '0.2.0',
        'bundle': 'segno-appliance-2.raucb',
        'sha256': 'abc123',
        'channel': 'experimental',
        'size': 131803622,
        'notes': 'wide splash + OTA title',
      });

      expect(manifest, isNotNull);
      expect(manifest!.version, Version.parse('0.2.0'));
      expect(manifest.bundle, 'segno-appliance-2.raucb');
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

  _pedalFirmwareTests();
}

void _pedalFirmwareTests() {
  group('pedalFirmware block', () {
    Map<String, dynamic> base() => <String, dynamic>{
      'version': '0.2.0',
      'bundle': 'b.raucb',
    };

    test('parses a well-formed block', () {
      final manifest = UpdateManifest.fromJson({
        ...base(),
        'pedalFirmware': <String, dynamic>{
          'version': '0.2.0',
          'hex': 'segno-pedal-0.2.0.hex',
          'protocolVersion': 3,
          'sha256': 'abc',
        },
      });

      final firmware = manifest?.pedalFirmware;
      expect(firmware?.version, Version.parse('0.2.0'));
      expect(firmware?.hex, 'segno-pedal-0.2.0.hex');
      expect(firmware?.protocolVersion, 3);
      expect(firmware?.sha256, 'abc');
    });

    test('a manifest with no block parses with a null firmware', () {
      // Every manifest published before the firmware artifact existed.
      expect(UpdateManifest.fromJson(base())?.pedalFirmware, isNull);
    });

    test('tolerates a quoted protocolVersion', () {
      final manifest = UpdateManifest.fromJson({
        ...base(),
        'pedalFirmware': <String, dynamic>{
          'version': '0.2.0',
          'hex': 'f.hex',
          'protocolVersion': '3',
        },
      });

      expect(manifest?.pedalFirmware?.protocolVersion, 3);
    });

    test('defaults protocolVersion to 0 (unknown) when absent', () {
      final manifest = UpdateManifest.fromJson({
        ...base(),
        'pedalFirmware': <String, dynamic>{'version': '0.2.0', 'hex': 'f.hex'},
      });

      expect(manifest?.pedalFirmware?.protocolVersion, 0);
    });

    // The OS update is the thing that must not break. A firmware block that is
    // malformed, half-written, or shaped for a future schema drops to null and
    // the bundle still installs.
    for (final (label, block) in <(String, Object)>[
      ('a non-map block', 'not-a-map'),
      ('a missing hex', <String, dynamic>{'version': '0.2.0'}),
      ('an empty hex', <String, dynamic>{'version': '0.2.0', 'hex': ''}),
      ('a missing version', <String, dynamic>{'hex': 'f.hex'}),
      (
        'an unparseable version',
        <String, dynamic>{'version': 'latest', 'hex': 'f.hex'},
      ),
      (
        'a non-string version',
        <String, dynamic>{'version': 2, 'hex': 'f.hex'},
      ),
    ]) {
      test('$label drops the firmware but keeps the bundle installable', () {
        final manifest = UpdateManifest.fromJson({
          ...base(),
          'pedalFirmware': block,
        });

        expect(manifest, isNotNull);
        expect(manifest?.bundle, 'b.raucb');
        expect(manifest?.pedalFirmware, isNull);
      });
    }

    test('differing firmware breaks manifest equality', () {
      UpdateManifest make(String hex) => UpdateManifest(
        version: Version.parse('0.2.0'),
        bundle: 'b.raucb',
        pedalFirmware: PedalFirmwareManifest(
          version: Version.parse('0.2.0'),
          hex: hex,
        ),
      );

      expect(make('a.hex'), make('a.hex'));
      expect(make('a.hex').hashCode, make('a.hex').hashCode);
      expect(make('a.hex'), isNot(make('b.hex')));
    });
  });
}
