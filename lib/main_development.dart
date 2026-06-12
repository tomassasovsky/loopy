import 'package:loopy/app/app.dart';
import 'package:loopy_engine/loopy_engine.dart';

Future<void> main(List<String> args) => runLoopy(
  args,
  createEngine: MockAudioEngine.new,
);
