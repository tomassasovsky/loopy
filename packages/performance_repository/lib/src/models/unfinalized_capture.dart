import 'package:meta/meta.dart';

/// A capture directory `PerformanceRepository.findUnfinalized` found whose
/// sidecar lacks `finalized: true` — evidence the app crashed (or was killed)
/// while armed, before `disarm`'s finalize path completed (D-SALVAGE).
@immutable
class UnfinalizedCapture {
  /// Creates an [UnfinalizedCapture].
  const UnfinalizedCapture({required this.directory, required this.slug});

  /// The capture's full directory path.
  final String directory;

  /// The bundle slug (the directory's basename).
  final String slug;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnfinalizedCapture &&
          runtimeType == other.runtimeType &&
          directory == other.directory &&
          slug == other.slug;

  @override
  int get hashCode => Object.hash(directory, slug);
}
