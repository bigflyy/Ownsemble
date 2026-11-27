// Tests for Remove from library (plan 06, C5): VK removes the song and the
// library hides it, Undo puts the same row back, a failure changes nothing
// and says why, a song in two accounts goes from both or from one, and
// History and Stacks keep a removed song's entries. VK's answers have the
// shapes the A2 probes saw on 2026-11-08; ids and keys are made up.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/search_index.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/collections_controller.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/song_remover.dart';
import 'package:ownsemble/vk/vk_sync.dart';

import 'merge_support.dart';

/// One account's VK library: answers audio.delete and audio.restore.
class FakeVkRemoves {
  FakeVkRemoves(this.userId);

  final int userId;

  /// Calls asked, as "method key".
  final asked = <String>[];

  /// The next delete answers that VK removed nothing.
  var refuseNext = false;

  /// The next call throws this.
  Object? failNext;

  /// The next audio.add answers "no access to audio", as real VK does.
  var refuseAddNext = false;

  /// The access key the last audio.add sent.
  String? addedWithKey;

  /// The audio id the next copy audio.add makes gets.
  var nextId = 900;

  Future<Object?> call(String method, Map<String, String> params) async {
    final key = '${params['owner_id']}_${params['audio_id']}';
    asked.add('$method $key');
    final fail = failNext;
    if (fail != null) {
      failNext = null;
      throw fail;
    }
    switch (method) {
      case 'audio.delete':
        if (refuseNext) {
          refuseNext = false;
          return {'audio_ids': <Object>[]};
        }
        return {
          'audio_ids': [key],
        };
      case 'audio.add':
        addedWithKey = params['access_key'];
        if (refuseAddNext) {
          refuseAddNext = false;
          return {
            'items': <Object>[],
            'errors': [
              {
                'error_code': '15;Access denied',
                'error_msg': 'no access to audio',
              },
            ],
          };
        }
        return {
          'items': [
            {'new_owner_id': userId, 'new_audio_id': nextId++},
          ],
        };
      case 'audio.restore':
        return {
          'owner_id': int.parse(params['owner_id']!),
          'id': int.parse(params['audio_id']!),
          'artist': 'Сплин',
          'title': 'Романс',
          'duration': 211,
          'date': 1762600000,
          'url': 'https://audio.invalid/x.mp3',
        };
    }
    throw StateError('unexpected $method');
  }
}

/// One VK song of [owner] as a sync reads it.
NewTrack song(int owner, int id, {String title = 'Романс'}) => vkItemToTrack({
  'owner_id': owner,
  'id': id,
  'artist': 'Сплин',
  'title': title,
  'duration': 211,
  'date': 1762600000 + id,
  'url': 'https://audio.invalid/$id.mp3',
});

void main() {
  late LibraryStore store;
  late int first;
  late int second;
  late FakeVkRemoves vk1;
  late FakeVkRemoves vk2;
  late bool secondLoggedIn;
  late ValueNotifier<List<SourceInfo>> sources;
  late int reloads;
  late List<String> perf;
  late SongRemover remover;

  setUp(() {
    store = LibraryStore.open(':memory:');
    first = store.ensureSource(TrackSource.vk, account: '42', name: 'Мой VK');
    second = store.ensureSource(TrackSource.vk, account: '43', name: 'Рабочий');
    vk1 = FakeVkRemoves(42);
    vk2 = FakeVkRemoves(43);
    secondLoggedIn = true;
    sources = ValueNotifier(store.sources());
    reloads = 0;
    perf = [];
    remover = SongRemover(
      store: store,
      sources: sources,
      apiOfSource: (id) => id == first
          ? vk1.call
          : id == second && secondLoggedIn
          ? vk2.call
          : null,
      onLibraryChanged: () => reloads++,
      slideTime: const Duration(milliseconds: 30),
      flashTime: const Duration(milliseconds: 30),
      log: perf.add,
    );
  });

  tearDown(() {
    remover.dispose();
    store.close();
  });

  Track listed(String title) =>
      store.loadAll().firstWhere((t) => t.title == title);
  List<String> listedTitles() => [for (final t in store.loadAll()) t.title];

  group('one account', () {
    late Track romance;
    setUp(() {
      store.upsertAll(first, [song(42, 1), song(42, 2, title: 'Выхода нет')]);
      romance = listed('Романс');
    });

    test('VK removes it, the row slides out, then the list drops it', () async {
      final pending = remover.remove(romance);
      expect(remover.leaving, {romance.id});
      final result = await pending;
      expect(vk1.asked, ['audio.delete 42_1']);
      expect(remover.leaving, isEmpty);
      expect(reloads, 1);
      expect(listedTitles(), ['Выхода нет']);
      expect(result.note, 'Removed "Романс" from Мой VK');
      expect(result.canUndo, isTrue);
      expect(store.sources().first.songCount, 1);
      // Counts and times only.
      expect(perf.single, startsWith('remove: 1 of 1 copies, VK '));
      expect(perf.single, isNot(contains('42_1')));
    });

    test('the list waits for the slide even when VK is quick', () async {
      final clock = Stopwatch()..start();
      await remover.remove(romance);
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(25));
    });

    test('Undo puts the same row back on VK and in the library, and '
        'flashes it', () async {
      final collections = CollectionsController(store)
        ..setFavorite(romance, true);
      final result = await remover.remove(romance);
      expect(await remover.undo(result), isNull);
      expect(vk1.asked, ['audio.delete 42_1', 'audio.restore 42_1']);
      expect(listed('Романс').id, romance.id);
      expect(listed('Романс').isGone, isFalse);
      expect(store.favorites().single.trackId, romance.id);
      expect(reloads, 2);
      expect(remover.flashing, romance.id);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(remover.flashing, isNull);
      expect(perf.last, startsWith('undo remove: 1 of 1 copies in '));
      collections.dispose();
    });

    test('VK removing nothing changes nothing and says so', () async {
      vk1.refuseNext = true;
      final result = await remover.remove(romance);
      expect(listedTitles(), ['Выхода нет', 'Романс']);
      expect(reloads, 0);
      expect(remover.leaving, isEmpty, reason: 'the row slides back');
      expect(result.canUndo, isFalse);
      expect(result.note, '"Романс" not removed: Мой VK: VK did not remove it');
    });

    test('no connection changes nothing and says so', () async {
      vk1.failNext = const SocketException('offline');
      final result = await remover.remove(romance);
      expect(listedTitles(), ['Выхода нет', 'Романс']);
      expect(result.note, '"Романс" not removed: Мой VK: no connection to VK');
    });

    test('a failed Undo says so and leaves the song removed', () async {
      final result = await remover.remove(romance);
      vk1.failNext = const SocketException('offline');
      expect(
        await remover.undo(result),
        'Could not bring back "Романс": Мой VK: no connection to VK',
      );
      expect(listedTitles(), ['Выхода нет']);
      expect(remover.flashing, isNull);
    });

    // The user, 2026-11-16: "on the ones that already were removed from VK
    // side undo doesnt work". VK answers "removed" for a song it does not
    // have, then cannot restore it: such a song never goes to VK.
    test('a song VK no longer has leaves only the library, and Undo lists '
        'it again without asking VK', () async {
      store.markGone(first, ['42_1'], atMs: 1000);
      final result = await remover.remove(listed('Романс'));
      expect(vk1.asked, isEmpty);
      expect(listedTitles(), ['Выхода нет']);
      expect(result.note, 'Removed "Романс" from Мой VK');
      expect(await remover.undo(result), isNull);
      expect(vk1.asked, isEmpty);
      expect(listed('Романс').goneAtMs, 1000);
      expect(remover.flashing, listed('Романс').id);
    });

    test('Undo asks for a sync after the running one', () async {
      var asked = 0;
      final withSync = SongRemover(
        store: store,
        sources: sources,
        apiOfSource: (_) => vk1.call,
        onLibraryChanged: () {},
        onPutOnVk: () => asked++,
        slideTime: Duration.zero,
      );
      final result = await withSync.remove(romance);
      expect(asked, 0);
      await withSync.undo(result);
      expect(asked, 1);
      withSync.dispose();
    });

    test('a second click while VK works removes it once', () async {
      final a = remover.remove(romance);
      final b = await remover.remove(romance);
      expect(b.canUndo, isFalse);
      expect(b.note, isEmpty);
      await a;
      expect(vk1.asked, ['audio.delete 42_1']);
    });

    test(
      'History and Stacks keep a removed song, Favorites does not',
      () async {
        final collections = CollectionsController(store);
        final play = collections.beginPlay(
          romance.id,
          start: PlayStart.chosen,
          shuffle: false,
        );
        collections.updatePlay(
          play,
          listenedMs: 211000,
          ended: PlayEnd.finished,
        );
        final stack = collections.createStack('Вечер');
        collections
          ..addToStack(stack, romance)
          ..setFavorite(romance, true);
        final library = LibraryController(
          store.loadAll(),
          collections: collections,
          removedSongs: store.loadRemoved,
        );
        await remover.remove(romance);
        final tracks = store.loadAll();
        library.replaceTracks(tracks, SearchIndex(tracks));
        List<int> shown(LibraryView view) {
          library.showView(view);
          return [for (final t in library.visible) t.id];
        }

        expect(shown(const LibraryView(ViewKind.history)), [romance.id]);
        expect(shown(LibraryView(ViewKind.stack, stackId: stack)), [
          romance.id,
        ]);
        expect(shown(const LibraryView(ViewKind.favorites)), isEmpty);
        // Searching History by its title still finds it (Codex review).
        library.showView(const LibraryView(ViewKind.history));
        library.searchText.text = 'романс';
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect([for (final t in library.visible) t.id], [romance.id]);
        library.searchText.text = 'нет такого';
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(library.visible, isEmpty);
        library.searchText.clear();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(shown(LibraryView.songs), isNot(contains(romance.id)));
        library.dispose();
        collections.dispose();
      },
    );
  });

  group('a song in two accounts', () {
    late Track romance;
    setUp(() {
      store.upsertAll(first, [song(42, 1)]);
      store.upsertAll(second, [song(43, 1)]);
      mergeSameFiles(store);
      sources.value = store.sources();
      romance = store.loadAll().single;
      expect(romance.copies, hasLength(1));
    });

    test('both accounts are offered, the listed row\'s first', () {
      expect(
        [for (final s in remover.accountsOf(romance)) s.name],
        ['Мой VK', 'Рабочий'],
      );
    });

    test('Remove from both asks each account and drops the song', () async {
      final result = await remover.remove(romance);
      expect(vk1.asked, ['audio.delete 42_1']);
      expect(vk2.asked, ['audio.delete 43_1']);
      expect(store.loadAll(), isEmpty);
      expect(result.note, 'Removed "Романс" from Мой VK and Рабочий');
      expect(await remover.undo(result), isNull);
      expect(store.loadAll().single.id, romance.id);
      expect(store.loadAll().single.copies, hasLength(1));
    });

    test(
      'Remove from one account keeps the song listed by the other',
      () async {
        final result = await remover.remove(romance, onlySource: second);
        expect(vk1.asked, isEmpty);
        expect(vk2.asked, ['audio.delete 43_1']);
        final row = store.loadAll().single;
        expect(row.id, romance.id);
        expect(row.copies, isEmpty);
        expect(
          result.note,
          'Removed "Романс" from Рабочий. It stays in Мой VK',
        );
        expect([for (final s in remover.accountsOf(row)) s.name], ['Мой VK']);
      },
    );

    // Codex review, 2026-11-16: removed from the listed row's own account,
    // the song is no longer that account's (source filter, colours).
    test('Remove from the listed row\'s account only: the song is no '
        'longer that account\'s', () async {
      await remover.remove(romance, onlySource: first);
      final row = store.loadAll().single;
      expect(row.id, romance.id);
      expect(row.isFrom(first), isFalse);
      expect(row.isFrom(second), isTrue);
      expect([for (final c in row.allCopies) c.sourceId], [second]);
      expect(row.isGone, isFalse);
    });

    test('one account failing keeps its copy and says so', () async {
      secondLoggedIn = false;
      final result = await remover.remove(romance);
      expect(vk1.asked, ['audio.delete 42_1']);
      expect(store.loadAll().single.copies.single.sourceKey, '43_1');
      expect(
        result.note,
        'Removed "Романс" from Мой VK. Not removed: Рабочий: not logged in',
      );
      expect(result.removed, hasLength(1));
    });
  });

  group('add a song another account has (plan 06, E2)', () {
    late Track romance;
    setUp(() {
      // The first account has a song of its own; the second alone has
      // "Романс", with the access key its sync read.
      store.upsertAll(first, [song(42, 5, title: 'Своё')]);
      store.upsertAll(second, [
        vkItemToTrack({
          'owner_id': 43,
          'id': 1,
          'artist': 'Сплин',
          'title': 'Романс',
          'duration': 211,
          'date': 1762600000,
          'access_key': 'theirs',
          'url': 'https://audio.invalid/1.mp3',
        }),
      ]);
      sources.value = store.sources();
      romance = listed('Романс');
    });

    test('only the account that lacks the song is offered', () {
      expect(
        [for (final s in remover.addableAccountsOf(romance)) s.name],
        ['Мой VK'],
      );
      expect(remover.addableAccountsOf(listed('Своё')).single.name, 'Рабочий');
    });

    test('an account that is not logged in is not offered', () {
      secondLoggedIn = false;
      expect(remover.addableAccountsOf(listed('Своё')), isEmpty);
    });

    test('VK adds it to the account, from the other account\'s copy with its '
        'key, and the song stays one row with both accounts', () async {
      final pending = remover.addTo(romance, first);
      expect(remover.adding, {romance.id});
      final note = await pending;
      expect(note, 'Added "Романс" to Мой VK');
      expect(remover.adding, isEmpty);
      expect(vk1.asked, ['audio.add 43_1']);
      expect(vk1.addedWithKey, 'theirs');
      expect(vk2.asked, isEmpty);
      expect(reloads, 1);
      expect(listedTitles(), unorderedEquals(['Своё', 'Романс']));
      final row = listed('Романс');
      expect(row.id, romance.id);
      expect([for (final c in row.allCopies) c.sourceKey], ['43_1', '42_900']);
      expect(row.isFrom(first), isTrue);
      expect(remover.addableAccountsOf(row), isEmpty);
      // Now in both: Remove offers each account alone.
      expect(
        [for (final s in remover.accountsOf(row)) s.name],
        ['Рабочий', 'Мой VK'],
      );
      expect(perf.single, startsWith('add to account: added, VK '));
    });

    test('it asks for a sync after the running one', () async {
      var asked = 0;
      final adder = SongRemover(
        store: store,
        sources: sources,
        apiOfSource: (id) => id == first ? vk1.call : null,
        onLibraryChanged: () {},
        onPutOnVk: () => asked++,
      );
      await adder.addTo(romance, first);
      expect(asked, 1);
      adder.dispose();
    });

    test('VK refusing changes nothing and says why', () async {
      vk1.refuseAddNext = true;
      final note = await remover.addTo(romance, first);
      expect(
        note,
        '"Романс" not added to Мой VK: VK gives no access to this song',
      );
      expect(reloads, 0);
      expect(listed('Романс').copies, isEmpty);
      expect(remover.adding, isEmpty);
    });

    test('no connection changes nothing and says so', () async {
      vk1.failNext = const SocketException('no route');
      final note = await remover.addTo(romance, first);
      expect(note, startsWith('"Романс" not added to Мой VK: '));
      expect(listed('Романс').copies, isEmpty);
    });

    test('a second click while VK works adds it once', () async {
      final firstClick = remover.addTo(romance, first);
      expect(await remover.addTo(romance, first), '');
      await firstClick;
      expect(vk1.asked, ['audio.add 43_1']);
    });

    test(
      'an account that already has it, or one logged out, is told so',
      () async {
        await remover.addTo(romance, first);
        expect(
          await remover.addTo(listed('Романс'), first),
          '"Романс" is already in Мой VK',
        );
        secondLoggedIn = false;
        expect(
          await remover.addTo(listed('Своё'), second),
          '"Своё" not added: Рабочий is not logged in',
        );
        expect(vk1.asked, ['audio.add 43_1']);
      },
    );

    // Review 2026-11-27: VK dropped the first account's copy; it can be
    // added again from the second account's.
    test('an account whose copy VK dropped is offered the add again', () async {
      await remover.addTo(romance, first);
      store.markGone(first, ['42_900']);
      final row = listed('Романс');
      expect(remover.addableAccountsOf(row).single.name, 'Мой VK');
      expect(await remover.addTo(row, first), 'Added "Романс" to Мой VK');
      expect(vk1.asked, ['audio.add 43_1', 'audio.add 43_1']);
      final copy = listed('Романс').copies.single;
      expect(copy.sourceKey, '42_901');
      expect(copy.goneAtMs, isNull);
    });

    test('a song no account has on VK any more offers no add', () {
      store.markGone(second, ['43_1']);
      expect(remover.addableAccountsOf(listed('Романс')), isEmpty);
    });
  });

  test('a song outside the library or generated offers no Remove', () {
    final generated = store.ensureSource(
      TrackSource.generated,
      account: null,
      name: 'Gen',
    );
    store.upsertAll(generated, [
      const NewTrack(
        sourceKey: 'g1',
        artist: 'A',
        title: 'B',
        durationSec: 1,
        addedAt: 0,
      ),
    ]);
    sources.value = store.sources();
    expect(remover.accountsOf(store.loadAll().single), isEmpty);
  });
}
