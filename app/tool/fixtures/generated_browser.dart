// Standalone VM probes deliberately avoid a Flutter package resolution step.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import '../../lib/contracts/music_browser.dart';

class GeneratedBrowserFactory implements MusicBrowserFactory {
  @override
  Set<BrowserCapability> capabilities = Set.of(BrowserCapability.values);
  @override
  bool prepared = false;
  final pages = <GeneratedBrowser>[];
  final events = <String>[];
  Completer<void>? preparing;
  bool muted = true, failMute = false, failOpen = false;
  Completer<void>? opening;
  Uri? redirect;
  int prepares = 0;
  @override
  Future<void> prepare() async {
    prepares++;
    await preparing?.future;
    prepared = true;
  }

  @override
  MusicBrowser create(BrowserEvents events) {
    final page = GeneratedBrowser(this, events);
    pages.add(page);
    return page;
  }
}

class GeneratedBrowser implements MusicBrowser {
  final GeneratedBrowserFactory factory;
  final BrowserEvents events;
  Uri? uri;
  bool closed = false;
  GeneratedBrowser(this.factory, this.events);
  void visit(Uri target) {
    uri = factory.redirect ?? target;
    events.started(uri);
    events.loaded(uri);
  }

  @override
  Future<void> open(Uri uri) async {
    factory.events.add('open:$uri');
    await factory.opening?.future;
    if (factory.failOpen) throw StateError('generated open failure');
    visit(uri);
  }

  @override
  Future<void> navigate(Uri uri) async {
    factory.events.add('navigate:$uri');
    visit(uri);
  }

  @override
  Future<void> reload() async {
    visit(uri!);
  }

  @override
  Future<Uri?> currentUrl() async => uri;
  @override
  Future<dynamic> evaluate(String expression) async {
    factory.events.add('evaluate');
    throw StateError('No extraction permitted in this fixture');
  }

  @override
  Future<void> addDocumentStartScript(String source) async {
    factory.events.add('script');
  }

  @override
  Future<bool> isAudioIsolated() async {
    factory.events.add('mute');
    if (factory.failMute) throw StateError('generated unavailable mute');
    return factory.muted;
  }

  @override
  Future<void> activate() async {}
  @override
  Future<void> pointer(BrowserPointer event) async {}
  @override
  Future<void> observeRequests(void Function(BrowserRequest) observed) async {}
  @override
  Future<void> showPrivateSignIn() async {
    factory.events.add('sign-in');
  }

  @override
  Future<void> finishPrivateSignIn() async {}
  @override
  Future<void> hide() async {
    factory.events.add('hide');
  }

  @override
  Future<bool> isHidden() async => true;
  @override
  Future<void> close() async {
    closed = true;
    events.exited();
  }
}
