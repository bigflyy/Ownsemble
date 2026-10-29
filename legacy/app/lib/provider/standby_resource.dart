import 'dart:async';

/// Own at most one prepared resource. Taking it transfers cleanup ownership
/// immediately, even while preparation is pending, so Stop can close it.
class PreparedResource<T> {
  final T value;
  final Future<void> Function(T) _dispose;
  late final Future<void> ready;
  Future<void>? _closing;
  bool isReady = false;
  PreparedResource(
    this.value,
    Future<void> Function(T) prepare,
    this._dispose,
  ) {
    ready = Future.sync(() => prepare(value)).then((_) {
      isReady = true;
    });
  }
  Future<void> close() => _closing ??= _dispose(value);
}

class StandbyResource<T> {
  final T Function() create;
  final Future<void> Function(T) prepare, dispose;
  final void Function(Object)? failed;
  PreparedResource<T>? _pending;
  StandbyResource({
    required this.create,
    required this.prepare,
    required this.dispose,
    this.failed,
  });
  bool get isReady => _pending?.isReady == true;
  bool get isPreparing => _pending != null && !isReady;

  /// Let an already-finishing warm-up win without blocking playback on a cold page.
  Future<bool> readyWithin(Duration budget) async {
    final resource = _pending;
    if (resource == null) return false;
    try {
      await resource.ready.timeout(budget);
    } catch (_) {
      // Preparation errors already have an observer and their own cleanup path.
      return false;
    }
    return identical(_pending, resource) && resource.isReady;
  }

  PreparedResource<T> _new() {
    final resource = PreparedResource(create(), prepare, dispose);
    resource.ready.then<void>(
      (_) {},
      onError: (Object error) {
        if (identical(_pending, resource)) _pending = null;
        failed?.call(error);
        unawaited(resource.close());
      },
    );
    return resource;
  }

  void warm() => _pending ??= _new();
  PreparedResource<T> take() {
    final resource = _pending ?? _new();
    _pending = null;
    return resource;
  }

  // The caller may return a ready document only if it never activated media.
  Future<void> returnUnused(PreparedResource<T> resource) async {
    if (_pending == null && resource.isReady && resource._closing == null) {
      _pending = resource;
    } else {
      await resource.close();
    }
  }

  Future<void> discard() async {
    final resource = _pending;
    _pending = null;
    if (resource == null) return;
    await resource.close();
    try {
      await resource.ready;
    } catch (_) {
      /* Already projected by failed. */
    }
  }
}
