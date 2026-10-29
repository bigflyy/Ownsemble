import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/library_navigation.dart';

void main() {
  test(
    'a stale guarded document cannot prevent a fresh approved-route navigation',
    () async {
      var fresh = false;
      final actions = <String>[];
      await prepareLibraryDocument(
        fromTop: true,
        requireMusicRoute: () async {
          actions.add('route');
        },
        reload: () async {
          fresh = true;
          actions.add('reload');
        },
        requirePersonal: () async {
          if (!fresh) throw const ProofFailure('private_signin_required');
          actions.add('fresh_guard');
        },
        install: () async {
          actions.add('install');
        },
        reset: () async {
          actions.add('reset');
        },
      );
      expect(actions, ['route', 'reload', 'fresh_guard', 'install', 'reset']);
    },
  );

  test('a real sign-in form after reload still stops before any adapter data access', () async {
    var accessed = false;
    await expectLater(
      prepareLibraryDocument(
        fromTop: true,
        requireMusicRoute: () async {},
        reload: () async {},
        requirePersonal: () async {
          throw const ProofFailure('private_signin_required');
        },
        install: () async {
          accessed = true;
        },
        reset: () async {
          accessed = true;
        },
      ),
      throwsA(isA<ProofFailure>()),
    );
    expect(accessed, isFalse);
  });

  test('an unapproved route cannot be reloaded or inspected', () async {
    var accessed = false;
    Future<void> access() async {
      accessed = true;
    }

    await expectLater(
      prepareLibraryDocument(
        fromTop: true,
        requireMusicRoute: () async {
          throw const ProofFailure('private_signin_required');
        },
        reload: access,
        requirePersonal: access,
        install: access,
        reset: access,
      ),
      throwsA(isA<ProofFailure>()),
    );
    expect(accessed, isFalse);
  });

  test('a continuing full slice keeps its viewport and checks its current document', () async {
    final actions = <String>[];
    await prepareLibraryDocument(
      fromTop: false,
      requireMusicRoute: () async {
        actions.add('route');
      },
      reload: () async {
        actions.add('reload');
      },
      requirePersonal: () async {
        actions.add('guard');
      },
      install: () async {
        actions.add('install');
      },
      reset: () async {
        actions.add('reset');
      },
    );
    expect(actions, ['guard', 'install']);
  });
}
