import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/sync/background_sync.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/player_bar.dart';
import 'package:ownsemble/ui/source_editor.dart';
import 'package:ownsemble/ui/sources_scope.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/ui/sync_status_bar.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:ownsemble/ui/vk_accounts.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_login_window.dart';
import 'package:ownsemble/vk/vk_session.dart';

import 'merge_support.dart';

class NoWindow implements LoginWindow {
  @override
  set onClosed(void Function() listener) {}

  @override
  Future<void> open() async {}

  @override
  Future<List<SessionCookie>> cookies() async => const [];

  @override
  Future<void> close() async {}
}

class Sessions implements VkSessionVault {
  final saved = <String, SavedSession>{};

  @override
  List<SavedSession> load() => saved.values.toList();

  @override
  String save(String account, List<SessionCookie> cookies) {
    saved[account] = SavedSession(account, account, cookies);
    return account;
  }

  @override
  String adopt(SavedSession session, String account) => session.id;

  @override
  void remove(String id) => saved.remove(id);
}

NewTrack song(String key, String title, {int trackId = 0}) => NewTrack(
  sourceKey: key,
  artist: 'Земфира',
  title: title,
  durationSec: 200,
  addedAt: 0,
  vkTrackId: trackId == 0 ? null : trackId,
);

void main() {
  late LibraryStore store;
  late Sessions sessions;
  late VkAccounts accounts;
  late SyncController sync;
  late LibraryController library;
  late SourceEditor editor;
  late int first;
  late int second;

  setUp(() {
    store = LibraryStore.open(':memory:');
    first = store.ensureSource(TrackSource.vk, account: '1', name: 'Анна');
    second = store.ensureSource(TrackSource.vk, account: '2', name: 'Борис');
    store.upsertAll(first, [song('1_1', 'Общая', trackId: 7)]);
    store.upsertAll(second, [
      song('2_1', 'Общая', trackId: 7),
      song('2_2', 'Только вторая'),
    ]);
    mergeSameFiles(store);
    sessions = Sessions()
      ..save('1', const [SessionCookie('remixsid', 'a', '.vk.ru')])
      ..save('2', const [SessionCookie('remixsid', 'b', '.vk.ru')]);
    accounts = VkAccounts(
      vault: sessions,
      window: NoWindow(),
      clientFor: (cookies) => VkClient(cookies),
    );
    library = LibraryController(store.loadAll());
    sync = SyncController(
      sources: store.sources(),
      runner: null,
      onLibraryChanged: (_) {},
    );
    editor = SourceEditor(
      store: store,
      sync: sync,
      library: library,
      dataDir: '.',
    );
  });
  tearDown(() => store.close());

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: SyncStatusBar(
            sync: sync,
            account: accounts,
            sources: editor,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('vk-accounts')));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('every account shows with its color and state', (tester) async {
    await openDialog(tester);
    expect(find.byKey(ValueKey('account-$first')), findsOneWidget);
    expect(find.byKey(ValueKey('account-$second')), findsOneWidget);
    expect(find.byKey(const ValueKey('vk-add-account')), findsOneWidget);
  });

  testWidgets('an account can be renamed', (tester) async {
    await openDialog(tester);
    await tapKey(tester, 'account-menu-$second');
    await tapKey(tester, 'account-rename');
    await tester.enterText(find.byKey(const ValueKey('account-name')), 'Рок');
    await tapKey(tester, 'account-name-save');
    expect(store.sources().last.name, 'Рок');
    expect(find.text('Рок'), findsWidgets);
  });

  testWidgets('a blank name changes nothing', (tester) async {
    await openDialog(tester);
    await tapKey(tester, 'account-menu-$second');
    await tapKey(tester, 'account-rename');
    await tester.enterText(find.byKey(const ValueKey('account-name')), '   ');
    await tapKey(tester, 'account-name-save');
    expect(store.sources().last.name, 'Борис');
  });

  testWidgets('an account can get another color', (tester) async {
    await openDialog(tester);
    await tapKey(tester, 'account-color-$second');
    await tapKey(tester, 'account-color-$second-4');
    expect(store.sources().last.color, 4);
  });

  testWidgets('logging out keeps the songs and offers no second log out', (
    tester,
  ) async {
    await openDialog(tester);
    await tapKey(tester, 'account-menu-$second');
    await tapKey(tester, 'vk-log-out');

    expect(accounts.sessions.single.account, '1');
    expect(store.sources(), hasLength(2));
    expect(find.textContaining('not logged in'), findsWidgets);
    await tapKey(tester, 'account-menu-$second');
    expect(find.byKey(const ValueKey('vk-log-out')), findsNothing);
  });

  testWidgets('removing asks first', (tester) async {
    await openDialog(tester);
    await tapKey(tester, 'account-menu-$second');
    await tapKey(tester, 'account-remove');
    expect(find.textContaining('Nothing changes on VK'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(store.sources(), hasLength(2));
    expect(accounts.sessions, hasLength(2));
  });

  testWidgets('removing takes the account and its own songs away', (
    tester,
  ) async {
    await openDialog(tester);
    await tapKey(tester, 'account-menu-$second');
    await tapKey(tester, 'account-remove');
    await tapKey(tester, 'account-remove-confirm');

    expect(sessions.saved.keys, ['1']);
    expect(store.sources().single.id, first);
    expect(library.all.single.title, 'Общая');
    expect(library.all.single.copies, isEmpty);
    expect(find.byKey(ValueKey('account-$second')), findsNothing);
  });

  testWidgets('removing an account that is logged out works too', (
    tester,
  ) async {
    await openDialog(tester);
    await tapKey(tester, 'account-menu-$second');
    await tapKey(tester, 'vk-log-out');
    await tapKey(tester, 'account-menu-$second');
    await tapKey(tester, 'account-remove');
    await tapKey(tester, 'account-remove-confirm');

    expect(accounts.sessions.single.account, '1');
    expect(store.sources().single.id, first);
  });

  group('where a song is from', () {
    Future<void> showTitle(WidgetTester tester, Track track) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(OwnColors.dark),
            home: SourcesScope(
              sources: sync.sourceList,
              child: Scaffold(body: SongTitle(track: track, large: true)),
            ),
          ),
        );

    Set<Color?> dots(WidgetTester tester) => tester
        .widgetList<Container>(
          find.byWidgetPredicate(
            (w) => w is Container && w.constraints?.maxWidth == 8,
          ),
        )
        .map((w) => (w.decoration! as BoxDecoration).color)
        .toSet();

    testWidgets('a song of one account has its name and color', (tester) async {
      await showTitle(
        tester,
        library.all.firstWhere((t) => t.title == 'Только вторая'),
      );
      expect(find.text('Борис - streams'), findsOneWidget);
      expect(dots(tester), {OwnColors.dark.source2});
    });

    testWidgets('a merged song names both accounts', (tester) async {
      await showTitle(
        tester,
        library.all.firstWhere((t) => t.title == 'Общая'),
      );
      expect(find.text('Анна, Борис - streams'), findsOneWidget);
      expect(dots(tester), {OwnColors.dark.source1, OwnColors.dark.source2});
    });

    testWidgets('a new color reaches what is on screen', (tester) async {
      await showTitle(
        tester,
        library.all.firstWhere((t) => t.title == 'Только вторая'),
      );
      editor.setColor(second, 5);
      await tester.pump();
      expect(dots(tester), {OwnColors.dark.source5});
    });
  });

  test('removing waits for a running sync', () async {
    final done = Future<SyncOutcome>.delayed(
      const Duration(milliseconds: 40),
      () => const SyncOutcome(sources: []),
    );
    sync.runner = (_) => done;
    sync.syncNow();
    await editor.remove(second);
    expect(sync.running, isFalse);
    expect(store.sources().single.id, first);
  });
}
