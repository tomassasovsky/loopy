/// Data client for the facts only the Segno appliance image knows about
/// itself: what its disk holds, what the box is, and where it can export to.
library;

export 'src/console_facts_client.dart' show ConsoleFactsClient;
export 'src/console_facts_models.dart' show ConsoleFacts, StorageUsage;
export 'src/fake_console_facts_client.dart' show FakeConsoleFactsClient;
export 'src/system_console_facts_client.dart'
    show createConsoleFactsClient, kFakeConsoleFacts;
export 'src/unsupported_console_facts_client.dart'
    show UnsupportedConsoleFactsClient;
