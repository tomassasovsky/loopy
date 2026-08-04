import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/run_segno.dart';
import 'package:segno/session_directory.dart';
import 'package:session_repository/session_repository.dart';

/// The mock flavor: a hardware-free engine that boots straight into the looper
/// with a deterministic default config, for UI work without an audio device.
///
/// The mock engine + its start config come from [createMockEngine], so this
/// entrypoint never imports the engine package. The single mock engine is
/// shared by all three repositories, matching the native wiring in
/// [runSegno].
Future<void> main(List<String> args) async {
  final mock = createMockEngine();
  await runSegno(
    args,
    repository: LooperRepository(engine: mock.engine),
    sessionRepository: SessionRepository(
      engine: mock.engine,
      sessionsRoot: defaultSessionsRoot,
    ),
    performanceRepository: PerformanceRepository(
      engine: mock.engine,
      exportsRoot: defaultExportDirectory,
    ),
    startConfig: mock.startConfig,
  );
}
