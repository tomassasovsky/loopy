import 'package:loopy/app/app.dart';
import 'package:loopy/bootstrap.dart';

Future<void> main() async {
  await bootstrap(() => const App());
}
