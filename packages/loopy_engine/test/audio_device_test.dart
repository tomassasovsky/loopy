import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

void main() {
  group('AudioDevice', () {
    test('exposes its fields', () {
      const device = AudioDevice(
        id: 'BuiltInSpeakerDevice',
        name: 'MacBook Pro Speakers',
        isDefault: true,
        isInput: false,
      );
      expect(device.id, 'BuiltInSpeakerDevice');
      expect(device.name, 'MacBook Pro Speakers');
      expect(device.isDefault, isTrue);
      expect(device.isInput, isFalse);
    });

    test('equal devices are equal and share a hashCode', () {
      const a = AudioDevice(
        id: 'mic-1',
        name: 'Scarlett 2i2',
        isDefault: false,
        isInput: true,
      );
      const b = AudioDevice(
        id: 'mic-1',
        name: 'Scarlett 2i2',
        isDefault: false,
        isInput: true,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('any differing field breaks equality', () {
      const base = AudioDevice(
        id: 'd',
        name: 'Device',
        isDefault: false,
        isInput: false,
      );
      expect(
        base,
        isNot(
          equals(
            const AudioDevice(
              id: 'other',
              name: 'Device',
              isDefault: false,
              isInput: false,
            ),
          ),
        ),
      );
      expect(
        base,
        isNot(
          equals(
            const AudioDevice(
              id: 'd',
              name: 'Other',
              isDefault: false,
              isInput: false,
            ),
          ),
        ),
      );
      expect(
        base,
        isNot(
          equals(
            const AudioDevice(
              id: 'd',
              name: 'Device',
              isDefault: true,
              isInput: false,
            ),
          ),
        ),
      );
      expect(
        base,
        isNot(
          equals(
            const AudioDevice(
              id: 'd',
              name: 'Device',
              isDefault: false,
              isInput: true,
            ),
          ),
        ),
      );
    });

    test('toString surfaces the key fields', () {
      const device = AudioDevice(
        id: 'd',
        name: 'My Device',
        isDefault: true,
        isInput: true,
      );
      final text = device.toString();
      expect(text, contains('My Device'));
      expect(text, contains('isDefault: true'));
      expect(text, contains('isInput: true'));
    });
  });
}
