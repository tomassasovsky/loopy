import 'package:flutter/material.dart';
import 'package:loopy/duplex_smoke/duplex_smoke.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// The root application widget.
class App extends StatelessWidget {
  /// Creates an [App] driven by [engine].
  ///
  /// The engine is injected so tests can supply a fake instead of opening the
  /// native audio device.
  const App({required this.engine, super.key});

  /// The audio engine that owns the native audio device.
  final AudioEngine engine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        appBarTheme: AppBarTheme(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        useMaterial3: true,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DuplexSmokePage(engine: engine),
    );
  }
}
