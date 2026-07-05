import 'package:meta/meta.dart';

/// One entry in the named-session catalog — a bundle under the `sessions/`
/// root, identified by its [name].
///
/// The [name] IS the folder slug (there is no separate persisted display name);
/// it is read straight from the directory listing, so a summary is produced
/// without ever parsing a manifest. Kept name-only on purpose: the picker needs
/// only the name to list, load, rename, and delete; richer metadata would force
/// a manifest read (and a parse-failure mode) per row for no acceptance need.
@immutable
class SessionSummary {
  /// Creates a [SessionSummary].
  const SessionSummary({required this.name});

  /// The session's name — also its folder slug under the sessions root.
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionSummary &&
          runtimeType == other.runtimeType &&
          name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'SessionSummary($name)';
}
