part of 'console_facts_cubit.dart';

/// Where the read of the console's own facts has got to.
enum ConsoleFactsStatus {
  /// Nothing read yet.
  initial,

  /// A read is in flight.
  loading,

  /// The last read came back.
  ready,

  /// The last read threw. Distinct from a build that cannot read at all: a
  /// desktop is [ConsoleFactsState.supported] `false` and never reaches here.
  failed,
}

/// What the app knows about the box it is running on.
class ConsoleFactsState extends Equatable {
  /// Creates a [ConsoleFactsState].
  const ConsoleFactsState({
    required this.supported,
    this.status = ConsoleFactsStatus.initial,
    this.storage = const StorageUsage.unknown(),
    this.facts = ConsoleFacts.unknown,
    this.exportDestination = '',
    this.givenName = '',
    this.busy = false,
  });

  /// Whether this build can read any of it.
  final bool supported;

  /// Where the last read got to.
  final ConsoleFactsStatus status;

  /// What the disk holds.
  final StorageUsage storage;

  /// What the box is.
  final ConsoleFacts facts;

  /// Where everything can be exported to, or empty for nowhere.
  final String exportDestination;

  /// The name the user gave this box, or empty while it still answers to the
  /// one the appliance shipped with.
  final String givenName;

  /// What the About face calls this console.
  String get consoleName => givenName.isEmpty ? facts.name : givenName;

  /// Whether a housekeeping action is running.
  final bool busy;

  /// Whether the Storage face can draw figures at all.
  ///
  /// A supported build whose read threw is NOT usable: zeroes drawn as facts
  /// would be worse than saying nothing, so the face replaces the whole card
  /// with one that says it cannot read the disk.
  bool get hasStorage => storage.known && status != ConsoleFactsStatus.failed;

  /// Returns a copy with the given fields replaced.
  ConsoleFactsState copyWith({
    bool? supported,
    ConsoleFactsStatus? status,
    StorageUsage? storage,
    ConsoleFacts? facts,
    String? exportDestination,
    String? givenName,
    bool? busy,
  }) => ConsoleFactsState(
    supported: supported ?? this.supported,
    status: status ?? this.status,
    storage: storage ?? this.storage,
    facts: facts ?? this.facts,
    exportDestination: exportDestination ?? this.exportDestination,
    givenName: givenName ?? this.givenName,
    busy: busy ?? this.busy,
  );

  @override
  List<Object?> get props => [
    supported,
    status,
    storage,
    facts,
    exportDestination,
    givenName,
    busy,
  ];
}
