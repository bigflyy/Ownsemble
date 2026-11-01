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
  ('Esc', 'Clear the search, then leave the search box'),
  ('F1', 'This list'),
];

/// Shows the list of keyboard shortcuts.
Future<void> showShortcutsHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) {
    final colors = OwnColors.of(context);
    return AlertDialog(
      key: const ValueKey('shortcuts-help'),
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (keys, action) in shortcuts)
              Padding(
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
                      child: Text(action, style: TextStyle(color: colors.dim)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'They work while you are not typing in a text field. A keyboard '
              "or headset's media keys work too.",
              style: TextStyle(fontSize: 13, color: colors.dim2),
            ),
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
