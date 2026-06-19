import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('NoopPedalTransport', () {
    const transport = NoopPedalTransport();

    test('enumerates no outputs and never opens', () {
      expect(transport.enumerateOutputs(), isEmpty);
      expect(transport.openOutput('x'), isNot(0)); // never succeeds
      expect(transport.closeOutput(), 0);
    });

    test('drops sends and exposes an empty input stream', () async {
      expect(transport.send(Uint8List.fromList([0xFA])), isNot(0));
      await expectLater(transport.input, emitsDone);
    });

    test('dispose completes', () {
      expect(transport.dispose(), completes);
    });

    test('a PedalRepository over it stays unbound and inert', () async {
      final repo = PedalRepository(const NoopPedalTransport());
      addTearDown(repo.dispose);

      expect(repo.availableOutputs(), isEmpty);
      repo
        ..bind('x') // openOutput fails -> error
        ..pushState(PedalStateFrame.blank());
      expect(repo.status, PedalBindStatus.error);
      expect(repo.boundOutputId, isNull);
    });
  });
}
