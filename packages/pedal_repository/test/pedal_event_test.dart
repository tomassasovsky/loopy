import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('PedalEvent', () {
    group('ButtonPressed', () {
      test('defaults timestamp to zero', () {
        expect(
          const ButtonPressed(PedalButton.recPlay).timestamp,
          Duration.zero,
        );
      });

      test('values with the same fields are equal', () {
        expect(
          const ButtonPressed(
            PedalButton.stop,
            timestamp: Duration(milliseconds: 5),
          ),
          const ButtonPressed(
            PedalButton.stop,
            timestamp: Duration(milliseconds: 5),
          ),
        );
      });

      test('differs by button and by timestamp', () {
        expect(
          const ButtonPressed(PedalButton.stop),
          isNot(const ButtonPressed(PedalButton.undo)),
        );
        expect(
          const ButtonPressed(PedalButton.stop),
          isNot(
            const ButtonPressed(
              PedalButton.stop,
              timestamp: Duration(milliseconds: 1),
            ),
          ),
        );
      });

      test('toString includes the button and timestamp', () {
        expect(
          const ButtonPressed(PedalButton.mode).toString(),
          contains('mode'),
        );
      });
    });

    group('ButtonReleased', () {
      test('values with the same fields are equal', () {
        expect(
          const ButtonReleased(PedalButton.bank),
          const ButtonReleased(PedalButton.bank),
        );
      });

      test('toString includes the button', () {
        expect(
          const ButtonReleased(PedalButton.clear).toString(),
          contains('clear'),
        );
      });
    });

    group('EncoderDelta', () {
      test('values with the same delta are equal', () {
        expect(const EncoderDelta(3), const EncoderDelta(3));
        expect(const EncoderDelta(3), isNot(const EncoderDelta(-3)));
      });

      test('toString includes the delta', () {
        expect(const EncoderDelta(-2).toString(), contains('-2'));
      });
    });

    test('the hierarchy is exhaustively switchable', () {
      String describe(PedalEvent event) => switch (event) {
        ButtonPressed() => 'pressed',
        ButtonReleased() => 'released',
        EncoderDelta() => 'encoder',
      };

      expect(describe(const ButtonPressed(PedalButton.recPlay)), 'pressed');
      expect(describe(const ButtonReleased(PedalButton.recPlay)), 'released');
      expect(describe(const EncoderDelta(1)), 'encoder');
    });
  });
}
