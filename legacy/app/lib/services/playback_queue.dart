import 'dart:math';

enum QueueRepeat { off, all, one }

class QueueEntry {
  final String id;
  final int? occurrence;
  const QueueEntry(this.id, [this.occurrence]);
  Map<String, dynamic> toJson() => {'id': id, 'occurrence': occurrence};
}

class PlaybackQueue {
  List<QueueEntry> entries = [];
  List<int> order = [];
  int cursor = -1;
  bool shuffle = false;
  QueueRepeat repeat = QueueRepeat.off;
  QueueEntry? get current =>
      cursor >= 0 && cursor < order.length ? entries[order[cursor]] : null;
  void replace(List<QueueEntry> items, int selected) {
    entries = List.of(items);
    order = List.generate(items.length, (i) => i);
    cursor = selected;
    if (shuffle) setShuffle(true);
  }

  void append(QueueEntry item) {
    entries.add(item);
    order.add(entries.length - 1);
    if (cursor < 0) cursor = 0;
  }

  void setShuffle(bool enabled, {Random? random}) {
    final active = cursor >= 0 && cursor < order.length ? order[cursor] : null;
    shuffle = enabled;
    order = List.generate(entries.length, (i) => i);
    if (enabled && active != null) {
      order.remove(active);
      order.shuffle(random);
      order.insert(0, active);
      cursor = 0;
    } else {
      cursor = active ?? (entries.isEmpty ? -1 : 0);
    }
  }

  QueueEntry? next({bool automatic = false}) {
    if (automatic && repeat == QueueRepeat.one) return current;
    if (cursor + 1 < order.length) {
      cursor++;
      return current;
    }
    if (repeat == QueueRepeat.all && order.isNotEmpty) {
      cursor = 0;
      return current;
    }
    return null;
  }

  QueueEntry? previous() {
    if (cursor > 0) cursor--;
    return current;
  }

  Map<String, dynamic> toJson() => {
    'entries': entries.map((e) => e.toJson()).toList(),
    'order': order,
    'cursor': cursor,
    'shuffle': shuffle,
    'repeat': repeat.index,
  };
  void restore(dynamic data) {
    try {
      final value = data as Map;
      final restored = (value['entries'] as List)
          .map((e) => QueueEntry(e['id'] as String, e['occurrence'] as int?))
          .toList();
      final restoredOrder = (value['order'] as List).cast<int>();
      final restoredCursor = value['cursor'] as int;
      if (restoredOrder.length != restored.length ||
          restoredOrder.toSet().length != restored.length ||
          restoredOrder.any((i) => i < 0 || i >= restored.length) ||
          restoredCursor < -1 ||
          restoredCursor >= restored.length) {
        return;
      }
      entries = restored;
      order = restoredOrder;
      cursor = restoredCursor;
      shuffle = value['shuffle'] == true;
      repeat = QueueRepeat.values[value['repeat'] as int];
    } catch (_) {
      entries = [];
      order = [];
      cursor = -1;
    }
  }
}
