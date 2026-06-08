import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/looper_view.dart';

/// Entry point for the looper feature.
///
/// Provides a [LooperBloc] backed by the shared [LooperRepository].
class LooperPage extends StatelessWidget {
  /// Creates a [LooperPage].
  const LooperPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => LooperBloc(
        repository: context.read<LooperRepository>(),
        controller: context.read<ControllerRepository>(),
      ),
      child: const LooperView(),
    );
  }
}
