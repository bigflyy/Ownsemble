import '../media/audio_policy.dart';

/// Capabilities are promises of an implementation, checked before any page opens.
/// Runtime mute verification is still mandatory: a declaration is not proof.
enum BrowserCapability {
  privateSession,
  hiddenDocument,
  requestObservation,
  trustedInput,
  nativeAudioIsolation,
  documentStartScript,
}

class BrowserRequest {
  final Uri? uri;
  final String kind;
  const BrowserRequest(this.uri, {this.kind = 'Other'});
}

enum PointerPhase { move, down, up }

class BrowserPointer {
  final PointerPhase phase;
  final double x, y;
  const BrowserPointer(this.phase, this.x, this.y);
}

class BrowserEvents {
  final void Function() exited, errored;
  final void Function(Uri?) started, loaded, historyChanged;
  final void Function(Uri?) request;
  final bool Function(Uri?) allowNavigation;
  const BrowserEvents({
    required this.exited,
    required this.errored,
    required this.started,
    required this.loaded,
    required this.historyChanged,
    required this.request,
    required this.allowNavigation,
  });
}

abstract interface class MusicBrowserFactory {
  Set<BrowserCapability> get capabilities;
  bool get prepared;
  Future<void> prepare();
  MusicBrowser create(BrowserEvents events);
}

abstract interface class MusicBrowser {
  Future<void> open(Uri uri);
  Future<void> navigate(Uri uri);
  Future<void> reload();
  Future<Uri?> currentUrl();
  Future<dynamic> evaluate(String expression);
  Future<void> addDocumentStartScript(String source);
  Future<bool> isAudioIsolated();
  Future<void> activate();
  Future<void> pointer(BrowserPointer event);
  Future<void> observeRequests(void Function(BrowserRequest) observed);
  Future<void> showPrivateSignIn();
  Future<void> finishPrivateSignIn();
  Future<void> hide();
  Future<bool> isHidden();
  Future<void> close();
}

class UnsupportedMusicBrowserFactory implements MusicBrowserFactory {
  const UnsupportedMusicBrowserFactory();
  @override
  Set<BrowserCapability> get capabilities => const {};
  @override
  bool get prepared => false;
  @override
  Future<void> prepare() async => _unsupported();
  @override
  MusicBrowser create(BrowserEvents events) => _unsupported();
  Never _unsupported() =>
      throw const ProofFailure('browser_capability_missing');
}

void requireMusicBrowserCapabilities(MusicBrowserFactory factory) {
  if (!factory.capabilities.containsAll(BrowserCapability.values)) {
    throw const ProofFailure('browser_capability_missing');
  }
}
