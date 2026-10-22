import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppCommand {
  playPause,
  mute,
  previous,
  next,
  volumeUp,
  volumeDown,
  seekBackward,
  seekForward,
  stop,
  shuffle,
  repeat,
  queue,
  search,
  leaveSearch,
  help,
}

class AppShortcut {
  final String label, hint;
  final LogicalKeyboardKey key;
  final PhysicalKeyboardKey? physicalKey;
  final bool control, alt, shift, repeats;
  const AppShortcut(
    this.label,
    this.hint,
    this.key, {
    this.physicalKey,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.repeats = false,
  });

  bool matches(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    return (event.logicalKey == key ||
            (physicalKey != null && event.physicalKey == physicalKey)) &&
        keyboard.isControlPressed == control &&
        keyboard.isAltPressed == alt &&
        keyboard.isShiftPressed == shift &&
        !keyboard.isMetaPressed;
  }
}

// Bindings, hover hints and the reference panel share this single definition.
// Physical letter fallbacks keep the same chord on Cyrillic keyboard layouts.
const appShortcuts = <AppCommand, AppShortcut>{
  AppCommand.playPause: AppShortcut(
    'Play / pause (cancel loading)',
    'Space',
    LogicalKeyboardKey.space,
  ),
  AppCommand.mute: AppShortcut(
    'Mute / unmute',
    'Ctrl+M',
    LogicalKeyboardKey.keyM,
    control: true,
    physicalKey: PhysicalKeyboardKey.keyM,
  ),
  AppCommand.previous: AppShortcut(
    'Previous song',
    'Ctrl+Left',
    LogicalKeyboardKey.arrowLeft,
    control: true,
  ),
  AppCommand.next: AppShortcut(
    'Next song',
    'Ctrl+Right',
    LogicalKeyboardKey.arrowRight,
    control: true,
  ),
  AppCommand.volumeUp: AppShortcut(
    'Volume up 5%',
    'Ctrl+Up',
    LogicalKeyboardKey.arrowUp,
    control: true,
    repeats: true,
  ),
  AppCommand.volumeDown: AppShortcut(
    'Volume down 5%',
    'Ctrl+Down',
    LogicalKeyboardKey.arrowDown,
    control: true,
    repeats: true,
  ),
  AppCommand.seekBackward: AppShortcut(
    'Back 5 seconds',
    'Alt+Left',
    LogicalKeyboardKey.arrowLeft,
    alt: true,
    repeats: true,
  ),
  AppCommand.seekForward: AppShortcut(
    'Forward 5 seconds',
    'Alt+Right',
    LogicalKeyboardKey.arrowRight,
    alt: true,
    repeats: true,
  ),
  AppCommand.stop: AppShortcut(
    'Stop',
    'Ctrl+.',
    LogicalKeyboardKey.period,
    control: true,
    physicalKey: PhysicalKeyboardKey.period,
  ),
  AppCommand.shuffle: AppShortcut(
    'Toggle shuffle',
    'Ctrl+Shift+S',
    LogicalKeyboardKey.keyS,
    control: true,
    shift: true,
    physicalKey: PhysicalKeyboardKey.keyS,
  ),
  AppCommand.repeat: AppShortcut(
    'Cycle repeat mode',
    'Ctrl+Shift+R',
    LogicalKeyboardKey.keyR,
    control: true,
    shift: true,
    physicalKey: PhysicalKeyboardKey.keyR,
  ),
  AppCommand.queue: AppShortcut(
    'Open queue',
    'Ctrl+Shift+Q',
    LogicalKeyboardKey.keyQ,
    control: true,
    shift: true,
    physicalKey: PhysicalKeyboardKey.keyQ,
  ),
  AppCommand.search: AppShortcut(
    'Search your music',
    'Ctrl+K',
    LogicalKeyboardKey.keyK,
    control: true,
    physicalKey: PhysicalKeyboardKey.keyK,
  ),
  AppCommand.leaveSearch: AppShortcut(
    'Leave search (keep query)',
    'Escape',
    LogicalKeyboardKey.escape,
  ),
  AppCommand.help: AppShortcut(
    'Keyboard shortcuts',
    'F1',
    LogicalKeyboardKey.f1,
  ),
};

String shortcutHint(AppCommand command, [String? label]) {
  final shortcut = appShortcuts[command]!;
  return '${label ?? shortcut.label} (${shortcut.hint})';
}

Future<void> showShortcutHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Keyboard shortcuts'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'While Ownsemble is focused. Playback shortcuts are inactive while typing; focused buttons keep their normal Space action.',
            ),
            const SizedBox(height: 16),
            for (final shortcut in appShortcuts.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(shortcut.label)),
                    const SizedBox(width: 20),
                    Text(
                      shortcut.hint,
                      style: const TextStyle(fontFamily: 'Consolas'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Escape closes the front dialog or queue first; in search it leaves the field and keeps your query. Ctrl+K returns to search.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      Tooltip(
        message: 'Close (Escape)',
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ),
    ],
  ),
);
