import 'package:flutter/material.dart';

import 'theme.dart';

/// What each keyboard shortcut does, in the order the list shows them.
const shortcuts = <(String keys, String action)>[
  ('Space', 'Play or pause'),
  ('Left, Right', 'Back or forward 5 seconds'),
  ('Ctrl + Left, Ctrl + Right', 'Previous or next song'),
  ('Up, Down', 'Volume up or down'),
  ('Ctrl + M', 'Mute or unmute'),
  ('Ctrl + S', 'Shuffle on or off'),
  ('Ctrl + R', 'Repeat: off, list, this song'),
  ('Ctrl + F', 'Search'),
  ('Ctrl + L', 'Go to the playing song in its list'),
  (
    'Alt + Left, Alt + Right',
    'Previous or next place, as the mouse side buttons',
  ),
  ('Letters', 'Jump to a matching song'),
  ('Up, Down after letters', 'Next or previous match'),
  ('Enter after letters', 'Play the song jumped to'),
  ('Ctrl + Backspace after letters', 'Delete the last word typed'),
  ('Esc', 'End the jump, clear the search, leave the search box'),
  ('F1 or Ctrl + /', 'This list'),
];

/// The lyrics editor's own keys (plan 10 I2g5): they work while the editor
/// shows, Ctrl+S and the line keys also while typing in a line.
const editorShortcuts = <(String keys, String action)>[
  ('Enter', 'Split the line at the cursor; at its end, a new line below'),
  ('Backspace at a line start', 'Join the line to the one above'),
  ('Up, Down while typing', 'The line above or below'),
  ('Ctrl + Z, Ctrl + Y', 'Undo or redo'),
  ('Ctrl + S', 'Save the edit'),
  ('Space in Tap to time', 'The marked line starts now'),
  ('Left, Down in Tap to time', 'Back a line, skip a line'),
  ('R in Tap to time', 'Play 3 seconds back'),
];

/// Shows the list of keyboard shortcuts; opened in the lyrics editor
/// ([editing]) its keys come first.
Future<void> showShortcutsHelp(BuildContext context, {bool editing = false}) =>
    showDialog<void>(
      context: context,
      builder: (context) {
        final colors = OwnColors.of(context);
        final player = [
          for (final (keys, action) in shortcuts)
            _ShortcutRow(keys: keys, action: action),
          const SizedBox(height: 8),
          Text(
            'They work while you are not typing in a text field. A keyboard '
            "or headset's media keys work too.",
            style: TextStyle(fontSize: 13, color: colors.dim2),
          ),
        ];
        final editor = [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'In the lyrics editor',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          for (final (keys, action) in editorShortcuts)
            _ShortcutRow(keys: keys, action: action),
        ];
        return AlertDialog(
          key: const ValueKey('shortcuts-help'),
          title: const Text('Keyboard shortcuts'),
          // The list is longer than a small window.
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...editing ? editor : player,
                const SizedBox(height: 14),
                if (editing)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Everywhere else',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                if (editing) const SizedBox(height: 4),
                ...editing ? player : editor,
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );

/// One key and what it does.
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.action});

  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 190,
          child: Text(
            keys,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Text(
            action,
            style: TextStyle(color: OwnColors.of(context).dim),
          ),
        ),
      ],
    ),
  );
}
