import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/update/update_backend.dart';

void main() {
  test(
    'createPlatformUpdateBackend is inert until a real backend is wired',
    () {
      // Until the appliance/desktop backends land, every platform gets the
      // unsupported backend, keeping the update UI hidden.
      expect(createPlatformUpdateBackend().isSupported, isFalse);
    },
  );
}
