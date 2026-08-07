import 'package:console_facts_client/src/console_facts_models.dart';

/// The four questions the System domain's Storage and About faces ask that
/// nothing else in the app can answer.
///
/// Narrow on purpose. It is not "the appliance": it is exactly what two faces
/// need, so a desktop build can answer *"I do not know"* to all of it in one
/// small class rather than by disabling two tabs. The faces key off the
/// absence — [StorageUsage.known] and the empty strings on [ConsoleFacts] —
/// so what they draw when the answer is missing is a decision they make, not
/// a default they inherit.
abstract interface class ConsoleFactsClient {
  /// Whether this build can answer any of the below.
  bool get isSupported;

  /// What the disk holds, or [StorageUsage.unknown].
  Future<StorageUsage> storage();

  /// What this console is, or [ConsoleFacts.unknown].
  Future<ConsoleFacts> facts();

  /// Deletes captures older than [days], returning how many went.
  ///
  /// The only write on this interface. It does **not** return the new usage:
  /// the caller re-reads [storage] afterwards, so what the face shows is
  /// measured rather than a model of what the delete should have done.
  Future<int> deleteCapturesOlderThan(int days);

  /// The mounted volume everything can be exported to, or an empty string
  /// when there is nowhere to export.
  ///
  /// Nowhere to export is a fact about the rig, not a failure: the row says
  /// so and stops being tappable, rather than failing under a finger.
  Future<String> exportDestination();

  /// Copies sessions, takes and captures to [destination].
  Future<void> exportEverything(String destination);
}
