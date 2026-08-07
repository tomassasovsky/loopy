import 'package:console_facts_client/src/console_facts_client.dart';
import 'package:console_facts_client/src/fake_console_facts_client.dart';
import 'package:console_facts_client/src/unsupported_console_facts_client.dart';

/// Whether `--dart-define=SEGNO_FAKE_RADIOS=true` swapped the appliance for an
/// in-memory stand-in.
///
/// The radios' own define, not a second one. Both flags would mean the same
/// thing — *this build is standing in for the appliance* — and a developer
/// holding two switches in their head to see one console is a worse cost than
/// a name that reads slightly wide of its contents.
const kFakeConsoleFacts = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// Factory: the fake under [kFakeConsoleFacts], else unsupported.
///
/// There is no real implementation yet, and that is the honest state of it:
/// disk accounting, capture retention and USB export do not exist on the
/// appliance side. The seam is the contract, and the shipped app answers
/// "unknown" rather than pretending otherwise.
ConsoleFactsClient createConsoleFactsClient() {
  if (kFakeConsoleFacts) return FakeConsoleFactsClient();
  return const UnsupportedConsoleFactsClient();
}
