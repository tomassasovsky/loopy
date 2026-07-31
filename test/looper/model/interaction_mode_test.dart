import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

/// The persisted-token contract: tokens derive from member names, so the
/// `play` -> `mute` rename must keep loading the token old installs stored —
/// these tests pin the legacy shim in [InteractionMode.fromToken].
void main() {
  group('InteractionMode', () {
    group('token', () {
      test('derives from the member name (new saves write "mute")', () {
        expect(InteractionMode.record.token, 'record');
        expect(InteractionMode.mute.token, 'mute');
        expect(InteractionMode.fx.token, 'fx');
      });
    });

    group('fromToken', () {
      test('parses the current tokens', () {
        expect(InteractionMode.fromToken('record'), InteractionMode.record);
        expect(InteractionMode.fromToken('mute'), InteractionMode.mute);
      });

      test('accepts the legacy pre-rename token "play" as mute', () {
        expect(InteractionMode.fromToken('play'), InteractionMode.mute);
      });

      test('defaults to record for null or unknown tokens', () {
        expect(InteractionMode.fromToken(null), InteractionMode.record);
        expect(InteractionMode.fromToken('bogus'), InteractionMode.record);
      });

      test('parses "fx" — the boot-default gate lives elsewhere', () {
        expect(InteractionMode.fromToken('fx'), InteractionMode.fx);
      });
    });

    group('bootDefaultFromToken (R12)', () {
      test('passes the boot-eligible modes through unchanged', () {
        expect(
          InteractionMode.bootDefaultFromToken('record'),
          InteractionMode.record,
        );
        expect(
          InteractionMode.bootDefaultFromToken('mute'),
          InteractionMode.mute,
        );
        // The legacy shim survives on this path too.
        expect(
          InteractionMode.bootDefaultFromToken('play'),
          InteractionMode.mute,
        );
      });

      test('coerces a stored "fx" to record — FX is never a boot mode', () {
        expect(
          InteractionMode.bootDefaultFromToken('fx'),
          InteractionMode.record,
        );
      });

      test('bootDefaults excludes fx', () {
        expect(
          InteractionMode.bootDefaults,
          isNot(contains(InteractionMode.fx)),
        );
      });
    });

    group('settings persistence', () {
      test('a stored legacy "play" default loads as mute', () async {
        final store = FakeKeyValueStore();
        // What an install that predates the rename has on disk under the
        // settings key — written by the old `play` member's token.
        store.values['looper.default_mode'] = 'play';
        final settings = SettingsRepository(store: store);

        final loaded = InteractionMode.fromToken(
          await settings.loadDefaultInteractionMode(),
        );

        expect(loaded, InteractionMode.mute);
      });

      test('a saved mute default round-trips through the repository', () async {
        final settings = SettingsRepository(store: FakeKeyValueStore());

        await settings.saveDefaultInteractionMode(InteractionMode.mute.token);

        expect(await settings.loadDefaultInteractionMode(), 'mute');
        expect(
          InteractionMode.fromToken(
            await settings.loadDefaultInteractionMode(),
          ),
          InteractionMode.mute,
        );
      });
    });
  });
}
