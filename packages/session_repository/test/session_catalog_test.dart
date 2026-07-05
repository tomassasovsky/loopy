import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/session_repository.dart';

import 'helpers/fake_session_engine.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('loopy_sessions_root');
  });
  tearDown(() => root.deleteSync(recursive: true));

  SessionRepository repo({bool withRoot = true}) => SessionRepository(
    engine: FakeSessionEngine(),
    sessionsRoot: withRoot ? () async => root.path : null,
  );

  /// Writes a bundle folder [slug] with a minimal manifest at schema [version].
  void makeBundle(String slug, {int version = 2}) {
    Directory('${root.path}/$slug').createSync(recursive: true);
    File('${root.path}/$slug/${Session.manifestName}').writeAsStringSync(
      '{"version":$version,"sampleRate":48000,"channels":1,'
      '"baseLengthFrames":0,"tracks":[]}',
    );
  }

  group('listSessions', () {
    test(
      'returns a summary per folder holding a manifest, skipping others',
      () async {
        makeBundle('Song A');
        makeBundle('Song B');
        Directory('${root.path}/not-a-session').createSync(); // no manifest

        final sessions = await repo().listSessions();

        expect(sessions.map((s) => s.name), ['Song A', 'Song B']);
      },
    );

    test('sorts alphabetically, case-insensitively', () async {
      makeBundle('zebra');
      makeBundle('Apple');
      makeBundle('mango');

      final names = (await repo().listSessions()).map((s) => s.name).toList();

      expect(names, ['Apple', 'mango', 'zebra']);
    });

    test(
      'lists a newer-version bundle without parsing it (never throws)',
      () async {
        // A manifest this build cannot load is still LISTED — enumeration only
        // stats for the file; the version error surfaces on an actual load.
        makeBundle('From The Future', version: 999);

        final sessions = await repo().listSessions();

        expect(sessions.single.name, 'From The Future');
      },
    );

    test('is empty when the root does not exist yet', () async {
      final missing = SessionRepository(
        engine: FakeSessionEngine(),
        sessionsRoot: () async => '${root.path}/never-created',
      );
      expect(await missing.listSessions(), isEmpty);
    });
  });

  group('bundlePath', () {
    test('resolves a name to its slug folder under the root', () async {
      expect(await repo().bundlePath('My Song'), '${root.path}/My Song');
      // The lossy fold applies here too, so name → path is stable.
      expect(await repo().bundlePath('My Song!'), '${root.path}/My Song');
    });

    test('throws ArgumentError for a name that sanitizes to nothing', () async {
      await expectLater(repo().bundlePath('   '), throwsArgumentError);
    });
  });

  group('renameSession', () {
    test('renames the bundle folder', () async {
      makeBundle('Old Name');

      await repo().renameSession('Old Name', 'New Name');

      expect(Directory('${root.path}/Old Name').existsSync(), isFalse);
      expect(Directory('${root.path}/New Name').existsSync(), isTrue);
    });

    test('throws SessionNameCollision when the target slug exists', () async {
      makeBundle('Keep');
      makeBundle('Clash');

      await expectLater(
        repo().renameSession('Keep', 'Clash'),
        throwsA(isA<SessionNameCollision>()),
      );
      expect(Directory('${root.path}/Keep').existsSync(), isTrue); // untouched
    });

    test('collides when two names fold to the same slug', () async {
      makeBundle('Source');
      makeBundle('My Song');

      // "My Song!" folds to the existing "My Song" slug.
      await expectLater(
        repo().renameSession('Source', 'My Song!'),
        throwsA(
          isA<SessionNameCollision>()
              .having((e) => e.slug, 'slug', 'My Song')
              .having((e) => e.toString(), 'message', contains('My Song')),
        ),
      );
    });

    test('renaming to the same slug is a no-op', () async {
      makeBundle('Same');
      await repo().renameSession('Same', 'Same!'); // folds back to "Same"
      expect(Directory('${root.path}/Same').existsSync(), isTrue);
    });

    test('throws ArgumentError when the new name is invalid', () async {
      makeBundle('Real');
      await expectLater(
        repo().renameSession('Real', '  '),
        throwsArgumentError,
      );
    });
  });

  group('duplicateSession', () {
    test('copies the bundle to a new independent folder', () async {
      makeBundle('Source');

      await repo().duplicateSession('Source', 'A Copy');

      expect(Directory('${root.path}/Source').existsSync(), isTrue);
      final copy = Directory('${root.path}/A Copy');
      expect(copy.existsSync(), isTrue);
      expect(
        File('${copy.path}/${Session.manifestName}').existsSync(),
        isTrue,
      );
    });

    test('throws SessionNameCollision when the target slug exists', () async {
      makeBundle('Source');
      makeBundle('Clash');
      await expectLater(
        repo().duplicateSession('Source', 'Clash'),
        throwsA(isA<SessionNameCollision>()),
      );
    });

    test('is a no-op when the source is missing', () async {
      await repo().duplicateSession('Ghost', 'New');
      expect(Directory('${root.path}/New').existsSync(), isFalse);
    });

    test('throws ArgumentError when the new name is invalid', () async {
      makeBundle('Source');
      await expectLater(
        repo().duplicateSession('Source', '  '),
        throwsArgumentError,
      );
    });
  });

  group('deleteSession', () {
    test('removes the bundle folder', () async {
      makeBundle('Doomed');
      await repo().deleteSession('Doomed');
      expect(Directory('${root.path}/Doomed').existsSync(), isFalse);
    });

    test('is a no-op for a missing session', () async {
      await expectLater(repo().deleteSession('Ghost'), completes);
    });

    test('is a no-op for an invalid name', () async {
      await expectLater(repo().deleteSession('   '), completes);
    });
  });

  group('without a configured root', () {
    test('the catalog methods throw StateError', () async {
      final noRoot = repo(withRoot: false);
      await expectLater(noRoot.listSessions(), throwsStateError);
      await expectLater(noRoot.bundlePath('x'), throwsStateError);
      await expectLater(noRoot.renameSession('a', 'b'), throwsStateError);
      await expectLater(noRoot.deleteSession('a'), throwsStateError);
    });
  });
}
