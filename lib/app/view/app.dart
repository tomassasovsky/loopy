import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';

/// The root application widget.
class App extends StatelessWidget {
  /// Creates an [App] driven by [repository].
  ///
  /// The repository (which owns the audio engine) is injected so tests can
  /// supply one backed by a fake engine instead of the native device.
  const App({required this.repository, super.key});

  /// The shared looper repository, provided to the widget tree.
  final LooperRepository repository;

  @override
  Widget build(BuildContext context) {
    return RepositoryProvider.value(
      value: repository,
      child: MaterialApp(
        theme: ThemeData(
          appBarTheme: AppBarTheme(
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          ),
          useMaterial3: true,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LooperPage(),
      ),
    );
  }
}
