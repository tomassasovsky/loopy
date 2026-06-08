import 'package:loopy/app/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy_engine/loopy_engine.dart';

Future<void> main() async {
  await bootstrap(() => App(engine: NativeAudioEngine()));
}
