part of 'console_facts_cubit.dart';

/// State for [ConsoleFactsCubit].
class ConsoleFactsState extends Equatable {
  /// Creates a [ConsoleFactsState].
  const ConsoleFactsState({
    this.usage = const StorageUsage(),
    this.facts = const ConsoleFacts(),
    this.canExport = false,
    this.busy = false,
    this.loaded = false,
  });

  /// What the disk holds.
  final StorageUsage usage;

  /// What this console is.
  final ConsoleFacts facts;

  /// Whether there is somewhere to export to.
  final bool canExport;

  /// Whether a housekeeping action is running.
  final bool busy;

  /// Whether the first read has come back.
  final bool loaded;

  /// Returns a copy with the given overrides.
  ConsoleFactsState copyWith({
    StorageUsage? usage,
    ConsoleFacts? facts,
    bool? canExport,
    bool? busy,
    bool? loaded,
  }) => ConsoleFactsState(
    usage: usage ?? this.usage,
    facts: facts ?? this.facts,
    canExport: canExport ?? this.canExport,
    busy: busy ?? this.busy,
    loaded: loaded ?? this.loaded,
  );

  @override
  List<Object?> get props => [
    usage.sessions,
    usage.captures,
    usage.plugins,
    usage.pluginCount,
    usage.system,
    usage.free,
    usage.known,
    facts.name,
    facts.serial,
    facts.systemImage,
    facts.panel,
    canExport,
    busy,
    loaded,
  ];
}
