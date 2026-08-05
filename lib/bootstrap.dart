import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:bloc/bloc.dart';
import 'package:flutter/widgets.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/logging/app_log.dart';

class AppBlocObserver extends BlocObserver {
  const AppBlocObserver();

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    // log('onChange(${bloc.runtimeType}, $change)');
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    log('onError(${bloc.runtimeType}, $error, $stackTrace)');
    AppLog.error(
      'bloc ${bloc.runtimeType}',
      error: error,
      stack: stackTrace,
    );
    super.onError(bloc, error, stackTrace);
  }
}

/// Opens the rotating logfile under `$HOME/log` and writes a process-start
/// breadcrumb. Call once near process entry (before audio auto-start) so early
/// failures are captured. Idempotent.
Future<void> initAppLogging() async {
  await AppLog.init(directory: AppLog.defaultDirectory());
  final alsaOnly = Platform.environment['SEGNO_ALSA_ONLY'] ?? '';
  final rtAudio = Platform.environment['SEGNO_RT_AUDIO'] ?? '';
  AppLog.info(
    'start pid=$pid console=$kConsoleMode '
    'os=${Platform.operatingSystem} '
    'SEGNO_ALSA_ONLY=$alsaOnly SEGNO_RT_AUDIO=$rtAudio',
  );
}

Future<void> bootstrap(FutureOr<Widget> Function() builder) async {
  FlutterError.onError = (details) {
    log(details.exceptionAsString(), stackTrace: details.stack);
    AppLog.error(
      'FlutterError',
      error: details.exception,
      stack: details.stack,
    );
  };

  // Return false so fatal isolate errors still tear down the process —
  // segno.service Restart=always then brings the kiosk back cleanly.
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error('PlatformDispatcher', error: error, stack: stack);
    return false;
  };

  Bloc.observer = const AppBlocObserver();

  // runApp must stay in the same zone as ensureInitialized (runSegno).
  // A nested runZonedGuarded triggers Flutter's zone-mismatch check and
  // can remount PlatformMenuBar.
  try {
    runApp(await builder());
  } on Object catch (error, stack) {
    AppLog.error('runApp', error: error, stack: stack);
    rethrow;
  }
}
