// Every text the app draws uses its own font, Golos Text. A style that sets
// only a size (a button's textStyle, the tooltip's or the popup menu's) used
// to replace the theme's label style instead of adding to it, so that text
// fell back to the system font (Segoe UI on Windows).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/ui/sync_controller.dart';
import 'package:ownsemble/ui/sync_status_bar.dart';
import 'package:ownsemble/ui/theme.dart';
import 'package:ownsemble/ui/vk_accounts.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_login_window.dart';
import 'package:ownsemble/vk/vk_session.dart';

const appFont = 'Golos Text';

/// A login window that never opens.
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

/// Saved sessions in memory; the cookies are made up and never sent.
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

/// The font family the text [label] is drawn with.
String? fontOf(WidgetTester tester, String label) => tester
    .renderObject<RenderParagraph>(find.text(label))
    .text
    .style
    ?.fontFamily;

void main() {
  late LibraryStore store;

  setUp(() {
    store = LibraryStore.open(':memory:');
    store.ensureSource(TrackSource.vk, account: '1', name: 'VK');
  });
  tearDown(() => store.close());

  /// The sync bar in the app's theme, with or without a saved session.
  Future<void> pumpBar(WidgetTester tester, {required bool loggedIn}) async {
    final sessions = Sessions();
    if (loggedIn) {
      sessions.save('1', const [SessionCookie('remixsid', 'a', '.vk.ru')]);
    }
    final accounts = VkAccounts(
      vault: sessions,
      window: NoWindow(),
      clientFor: (cookies) => VkClient(cookies),
    );
    final sync = SyncController(
      sources: store.sources(),
      runner: null,
      onLibraryChanged: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(OwnColors.dark),
        home: Scaffold(
          bottomNavigationBar: SyncStatusBar(sync: sync, account: accounts),
        ),
      ),
    );
  }

  testWidgets('the Sync now button uses the app font', (tester) async {
    await pumpBar(tester, loggedIn: true);
    expect(fontOf(tester, 'Sync now'), appFont);
  });

  testWidgets('the log in button uses the app font', (tester) async {
    await pumpBar(tester, loggedIn: false);
    expect(find.byType(LogInButton), findsOneWidget);
    final label = tester
        .widget<Text>(
          find.descendant(
            of: find.byType(LogInButton),
            matching: find.byType(Text),
          ),
        )
        .data!;
    expect(fontOf(tester, label), appFont);
  });

  testWidgets('tooltips use the app font', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(OwnColors.light),
        home: const Scaffold(
          body: Center(
            child: Tooltip(message: 'Подсказка', child: Text('target')),
          ),
        ),
      ),
    );
    tester.state<TooltipState>(find.byType(Tooltip)).ensureTooltipVisible();
    await tester.pumpAndSettle();
    expect(fontOf(tester, 'Подсказка'), appFont);
  });

  testWidgets('popup menu items use the app font', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(OwnColors.dark),
        home: Scaffold(
          body: PopupMenuButton<int>(
            key: const ValueKey('menu'),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 1, child: Text('Переименовать...')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('menu')));
    await tester.pumpAndSettle();
    expect(fontOf(tester, 'Переименовать...'), appFont);
  });
}
