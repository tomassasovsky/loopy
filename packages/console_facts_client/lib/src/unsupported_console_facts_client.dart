import 'package:console_facts_client/src/console_facts_client.dart';
import 'package:console_facts_client/src/console_facts_models.dart';

/// What a build that is not the appliance answers: nothing, honestly.
///
/// This is what the app gets today on every platform. It is not a stub waiting
/// to be filled in at the call sites — it *is* the correct answer for a
/// desktop build, and the faces are written against it first.
class UnsupportedConsoleFactsClient implements ConsoleFactsClient {
  /// Creates an [UnsupportedConsoleFactsClient].
  const UnsupportedConsoleFactsClient();

  @override
  bool get isSupported => false;

  @override
  Future<StorageUsage> storage() async => const StorageUsage.unknown();

  @override
  Future<ConsoleFacts> facts() async => ConsoleFacts.unknown;

  @override
  Future<int> deleteCapturesOlderThan(int days) async => 0;

  @override
  Future<String> exportDestination() async => '';

  @override
  Future<void> exportEverything(String destination) async {}
}
