import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy_engine/loopy_engine.dart';

Future<void> main() async {
  final repository = LooperRepository(engine: NativeAudioEngine());
  await bootstrap(() => App(repository: repository));
}
