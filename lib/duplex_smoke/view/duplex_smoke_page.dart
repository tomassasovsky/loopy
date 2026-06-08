import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/duplex_smoke/cubit/duplex_smoke_cubit.dart';
import 'package:loopy/duplex_smoke/view/duplex_smoke_view.dart';
import 'package:loopy_engine/loopy_engine.dart';

/// Entry point for the Phase-1 duplex smoke harness.
///
/// Provides a [DuplexSmokeCubit] backed by the injected [AudioEngine].
class DuplexSmokePage extends StatelessWidget {
  /// Creates a [DuplexSmokePage].
  const DuplexSmokePage({required this.engine, super.key});

  /// The audio engine driven by this harness.
  final AudioEngine engine;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => DuplexSmokeCubit(engine),
      child: const DuplexSmokeView(),
    );
  }
}
