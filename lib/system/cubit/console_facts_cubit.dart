import 'package:bloc/bloc.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';

part 'console_facts_state.dart';

/// Reads what the appliance knows about itself, and runs the one housekeeping
/// action that changes it.
///
/// Read-mostly, and provided app-wide rather than by the face: the facts are
/// about the box, not about a screen, and the About tab must not be the only
/// thing that can ask. [load] runs on create; the Storage face re-reads on
/// open, because a USB stick may have arrived since.
class ConsoleFactsCubit extends Cubit<ConsoleFactsState> {
  /// Creates a [ConsoleFactsCubit].
  ConsoleFactsCubit({
    required ConsoleFactsClient client,
    required SettingsRepository settings,
  }) : _client = client,
       _settings = settings,
       super(ConsoleFactsState(supported: client.isSupported));

  final ConsoleFactsClient _client;
  final SettingsRepository _settings;

  /// Reads the disk, the box's own facts and the export destination.
  ///
  /// Safe to call repeatedly — the Storage face calls it every time it opens.
  /// Reports [ConsoleFactsStatus.failed] rather than throwing: a face that
  /// cannot read the disk says so, and there is nothing above it to catch.
  Future<void> load() async {
    emit(
      state.copyWith(
        status: ConsoleFactsStatus.loading,
        actionFailed: false,
      ),
    );
    try {
      final storage = await _client.storage();
      final facts = await _client.facts();
      final destination = await _client.exportDestination();
      // Keyed off the serial, so a settings store carried to a second console
      // does not arrive claiming to be the first one.
      final given = facts.serial.isEmpty
          ? null
          : await _settings.loadConsoleName(facts.serial);
      if (isClosed) return;
      emit(
        state.copyWith(
          status: ConsoleFactsStatus.ready,
          storage: storage,
          facts: facts,
          exportDestination: destination,
          givenName: given ?? '',
        ),
      );
    } on Object {
      if (!isClosed) emit(state.copyWith(status: ConsoleFactsStatus.failed));
    }
  }

  /// Deletes captures older than [days] and then **re-reads** the disk.
  ///
  /// The only write this cubit makes, and it does not model its own effect:
  /// what the face shows afterwards is measured, not the figures it held minus
  /// what the delete claimed to remove.
  ///
  /// Returns nothing, and the client's own count is dropped on the floor here
  /// deliberately: a cubit's output is its state, and no face draws "14
  /// captures removed". The figures after the re-read are the answer.
  Future<void> deleteCapturesOlderThan(int days) async {
    emit(state.copyWith(busy: true, actionFailed: false));
    try {
      await _client.deleteCapturesOlderThan(days);
      if (isClosed) return;
      emit(state.copyWith(busy: false));
      await load();
    } on Object {
      // The ACTION failed, not the read: the figures already on screen were
      // measured and are still true.
      if (!isClosed) emit(state.copyWith(busy: false, actionFailed: true));
    }
  }

  /// Names this console.
  ///
  /// A no-op on a build with no serial to hang the name off — which is also a
  /// build whose About face draws no name row, so nothing can call it there.
  /// An empty [name] hands the box back the name it shipped with, rather than
  /// storing a blank one the next reader has to know to ignore.
  Future<void> rename(String name) async {
    final serial = state.facts.serial;
    if (serial.isEmpty) return;
    final trimmed = name.trim();
    // The store first, the screen second. Emitting optimistically and then
    // awaiting would leave a face showing a name the store refused — the one
    // failure mode a rename has, and the one this face has nowhere to report.
    // A write that throws leaves the old name up, which is the truth.
    try {
      if (trimmed.isEmpty) {
        await _settings.clearConsoleName(serial);
      } else {
        await _settings.saveConsoleName(serial, trimmed);
      }
    } on Object {
      return;
    }
    if (!isClosed) emit(state.copyWith(givenName: trimmed));
  }

  /// Copies everything to the mounted export volume. No-op when there is
  /// nowhere to export — the row that calls this is not tappable then, and
  /// this repeats the check rather than trusting the caller's.
  Future<void> exportEverything() async {
    final destination = state.exportDestination;
    if (destination.isEmpty) return;
    emit(state.copyWith(busy: true, actionFailed: false));
    try {
      await _client.exportEverything(destination);
      if (!isClosed) emit(state.copyWith(busy: false));
    } on Object {
      // Same rule as the delete: a refused write is not an unreadable disk.
      if (!isClosed) emit(state.copyWith(busy: false, actionFailed: true));
    }
  }
}
