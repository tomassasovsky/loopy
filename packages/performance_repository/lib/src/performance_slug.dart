/// Folds [timestamp] into a performance bundle slug: `perf-YYYYMMDD-HHMMSS`
/// (D-NAME). Second-resolution and purely time-derived, so two arms in the
/// same wall-clock second collide — `PerformanceRepository` appends a `-N`
/// disambiguator in that (practically unreachable, since arming twice in one
/// second implies an instant disarm+rearm) case rather than silently
/// overwriting the earlier bundle.
String performanceSlug(DateTime timestamp) {
  String pad(int n, int width) => n.toString().padLeft(width, '0');
  return 'perf-${pad(timestamp.year, 4)}${pad(timestamp.month, 2)}'
      '${pad(timestamp.day, 2)}-${pad(timestamp.hour, 2)}'
      '${pad(timestamp.minute, 2)}${pad(timestamp.second, 2)}';
}
