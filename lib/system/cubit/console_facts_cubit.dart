import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/system/client/console_facts.dart';

part 'console_facts_state.dart';

/// Reads what the console is and what its disk holds, for the Storage and
/// About faces.
///
/// Read-mostly: the only write is the housekeeping action, and it re-reads
/// afterwards rather than guessing at the new figures.
class ConsoleFactsCubit extends Cubit<ConsoleFactsState> {
  /// Creates a [ConsoleFactsCubit].
  ConsoleFactsCubit({required ConsoleFactsClient client})
    : _client = client,
      super(const ConsoleFactsState());

  final ConsoleFactsClient _client;

  /// Reads the disk and the identity. Safe to call again — the face does, on
  /// every open, because a USB stick may have arrived since.
  Future<void> load() async {
    final usage = await _client.usage();
    final facts = await _client.facts();
    final exportable = await _client.hasExportTarget();
    if (isClosed) return;
    emit(
      state.copyWith(
        usage: usage,
        facts: facts,
        canExport: exportable,
        loaded: true,
      ),
    );
  }

  /// Deletes captures older than [days] and re-reads what is left.
  Future<void> deleteCapturesOlderThan(int days) async {
    if (isClosed) return;
    emit(state.copyWith(busy: true));
    await _client.deleteCapturesOlderThan(days);
    if (isClosed) return;
    emit(state.copyWith(busy: false));
    await load();
  }
}
