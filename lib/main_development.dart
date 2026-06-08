import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/app/app.dart';
import 'package:loopy/bootstrap.dart';
import 'package:loopy_engine/loopy_engine.dart';

Future<void> main() async {
  final repository = LooperRepository(engine: NativeAudioEngine());
  final controllerRepository = ControllerRepository(sources: const []);
  await bootstrap(
    () => App(
      repository: repository,
      controllerRepository: controllerRepository,
    ),
  );
}
