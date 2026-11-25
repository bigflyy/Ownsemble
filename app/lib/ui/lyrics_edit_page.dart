/// The lyrics editor place (plan 10 I2g, mockup board 1 picked 2026-11-25):
/// one row per line with its start time, -/+ 0.1 s, "now" and the text;
/// Tap to time on the same rows (Space at each line's start); Edit as text
/// for many fixes or pasting whole lyrics. Saved as the user's own version
/// beside the sources (LyricsController.saveEdit).
///
/// The editor works on one upload: the song it opened for. Its times follow
/// the player only while that song plays; the song starts again at its end
/// while the editor is open (PlaybackController.holdSong).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/track.dart';
import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_edit.dart';
import '../lyrics/lyrics_editor.dart';
import '../lyrics/lyrics_sources.dart' show lyricsSourceLabel;
import 'lyrics_page.dart' show lyricsLeadMs, lyricsNarrowWidth;
import 'theme.dart';

/// Below this width of the place the editor's heading buttons are icons.
const lyricsEditLabelWidth = 900.0;

/// "Slower" plays at this speed while tapping times.
const tapSlowRate = 0.75;

/// The keys of Tap to time as its bar shows them (mockup board 2).
const tapKeys = <(String key, String words)>[
  ('Space', 'line starts now'),
  ('←', 'back a line'),
  ('↓', 'skip a line'),
  ('R', 'play 3 s back'),
];

/// One opening of the editor: its working copy, the upload and base it is
/// for, and the place's own switches (text mode, slower).
class LyricsEditSession extends ChangeNotifier {
  LyricsEditSession({
    required List<LyricLine> start,
    required this.uploadKey,
    required this.basedOn,
    required this.track,
  }) : editor = LyricsEditor(start) {
    editor.addListener(notifyListeners);
  }

  final LyricsEditor editor;

  /// The upload the edit is for and the source it starts from (null:
  /// written from nothing).
  final String uploadKey;
  final String? basedOn;

  /// The song the editor opened for.
  final Track track;

  /// The text of "Edit as text" while it is open; null on the rows.
  TextEditingController? _text;
  TextEditingController? get text => _text;
  bool get textMode => _text != null;

  bool _slower = false;
  bool get slower => _slower;

  /// Whether anything differs from what the editor opened with, the text
  /// being typed included.
  bool get changed =>
      editor.changed || (_text != null && _text!.text != editor.text);

  void openText() {
    if (_text != null) return;
    editor.stopTapping();
    _text = TextEditingController(text: editor.text)
      ..addListener(notifyListeners);
    notifyListeners();
  }

  /// Back to the rows: the typed text becomes the rows (times kept where
  /// lines stay), when it changed.
  void closeText() {
    final controller = _text;
    if (controller == null) return;
    if (controller.text != editor.text) editor.applyText(controller.text);
    _text = null;
    controller.dispose();
    notifyListeners();
  }

  void setSlower(bool value) {
    _slower = value;
    notifyListeners();
  }

  /// The lines to save: the text applied first when it is open.
  List<LyricLine> finish() {
    closeText();
    return editor.result;
  }

  @override
  void dispose() {
    editor.removeListener(notifyListeners);
    _text?.dispose();
    editor.dispose();
    super.dispose();
  }
}

/// The editor's own keys, from the screen's app-wide key handler (they run
/// before the focus tree): in Tap to time Space times the next line, Left
/// goes back a line, Down skips one and R plays 3 s back; Ctrl+Z and Ctrl+Y
/// undo and redo outside a text field (inside one the field's own undo is
/// overridden, see [LyricsEditPage]); Ctrl+S saves, also while typing (in
/// the editor it is Save, as in any editor, not Shuffle). True when the key
/// was used.
bool onLyricsEditKey(
  LyricsEditSession session,
  KeyEvent event, {
  required bool typing,
  required bool songPlaying,
  required int positionMs,
  required Future<void> Function(Duration to) seek,
  required VoidCallback onSave,
}) {
  if (event is! KeyDownEvent) return false;
  final editor = session.editor;
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isControlPressed &&
      event.physicalKey == PhysicalKeyboardKey.keyS) {
    onSave();
    return true;
  }
  if (keyboard.isControlPressed && !typing) {
    if (event.physicalKey == PhysicalKeyboardKey.keyZ) {
      keyboard.isShiftPressed ? editor.redo() : editor.undo();
      return true;
    }
    if (event.physicalKey == PhysicalKeyboardKey.keyY) {
      editor.redo();
      return true;
    }
  }
  if (!editor.tapping || session.textMode) return false;
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.space) {
    if (songPlaying) editor.tap(positionMs);
    return true;
  }
  if (key == LogicalKeyboardKey.arrowLeft) {
    editor.tapBack();
    return true;
  }
  if (key == LogicalKeyboardKey.arrowDown) {
    editor.tapSkip();
    return true;
  }
  if (event.physicalKey == PhysicalKeyboardKey.keyR) {
    if (songPlaying) {
      final back = positionMs - tapReplayMs;
      unawaited(seek(Duration(milliseconds: back < 0 ? 0 : back)));
    }
    return true;
  }
  return false;
}

/// The heading's buttons in the editor: Undo, Redo, Tap to time, Edit as
/// text, Cancel, Save. With [compact] every button is an icon with its
/// words in the tooltip (the heading's rule: words for all or for none).
class LyricsEditActions extends StatelessWidget {
  const LyricsEditActions({
    super.key,
    required this.session,
    required this.compact,
    required this.onTapping,
    required this.onCancel,
    required this.onSave,
  });

  final LyricsEditSession session;
  final bool compact;

  /// Tap to time switched on (true) or off.
  final void Function(bool on) onTapping;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final editor = session.editor;
      final colors = OwnColors.of(context);
      Widget button({
        required Key key,
        required IconData icon,
        required String label,
        required VoidCallback? onPressed,
        bool on = false,
      }) => compact
          ? IconButton(
              key: key,
              tooltip: label,
              isSelected: on,
              onPressed: onPressed,
              icon: Icon(icon),
            )
          : on
          ? FilledButton.tonalIcon(
              key: key,
              onPressed: onPressed,
              icon: Icon(icon, size: 20),
              label: Text(label),
            )
          : TextButton.icon(
              key: key,
              onPressed: onPressed,
              icon: Icon(icon, size: 20),
              label: Text(label),
            );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('lyrics-edit-undo'),
            tooltip: 'Undo (Ctrl+Z)',
            onPressed: editor.canUndo && !session.textMode ? editor.undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            key: const ValueKey('lyrics-edit-redo'),
            tooltip: 'Redo (Ctrl+Y)',
            onPressed: editor.canRedo && !session.textMode ? editor.redo : null,
            icon: const Icon(Icons.redo),
          ),
          button(
            key: const ValueKey('lyrics-edit-tap'),
            icon: Icons.timer_outlined,
            label: 'Tap to time',
            on: editor.tapping,
            onPressed: session.textMode
                ? null
                : () => onTapping(!editor.tapping),
          ),
          button(
            key: const ValueKey('lyrics-edit-text'),
            icon: session.textMode ? Icons.format_list_bulleted : Icons.notes,
            label: session.textMode ? 'Back to lines' : 'Edit as text',
            on: session.textMode,
            onPressed: session.textMode ? session.closeText : session.openText,
          ),
          button(
            key: const ValueKey('lyrics-edit-cancel'),
            icon: Icons.close,
            label: 'Cancel',
            onPressed: onCancel,
          ),
          const SizedBox(width: 4),
          compact
              ? IconButton.filled(
                  key: const ValueKey('lyrics-edit-save'),
                  tooltip: 'Save',
                  style: IconButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                  ),
                  onPressed: onSave,
                  icon: const Icon(Icons.check),
                )
              : FilledButton(
                  key: const ValueKey('lyrics-edit-save'),
                  onPressed: onSave,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                  ),
                  child: const Text('Save'),
                ),
        ],
      );
    },
  );
}

/// What the editor's heading says under its title.
String lyricsEditDetail(LyricsEditSession session) {
  final track = session.track;
  final song = track.artist.isEmpty
      ? track.title
      : '${track.title} - ${track.artist}';
  final base = session.basedOn;
  return base == null
      ? '$song · new lyrics'
      : base == editedSource
      ? '$song · your edit'
      : '$song · from ${lyricsSourceLabel(base)}';
}

class LyricsEditPage extends StatefulWidget {
  const LyricsEditPage({
    super.key,
    required this.session,
    required this.position,
    required this.positions,
    required this.seek,
    required this.songPlaying,
    required this.onPlaySong,
  });

  final LyricsEditSession session;

  /// Where the playing song is, and its positions while it plays (null
  /// until the player is ready).
  final Duration Function() position;
  final Stream<Duration>? Function() positions;
  final Future<void> Function(Duration to) seek;

  /// Whether the song being edited is the one playing: times follow the
  /// player only then.
  final bool Function() songPlaying;

  /// Plays the song being edited.
  final VoidCallback onPlaySong;

  @override
  State<LyricsEditPage> createState() => _LyricsEditPageState();
}

class _LyricsEditPageState extends State<LyricsEditPage> {
  final _fields = <int, TextEditingController>{};
  final _focus = <int, FocusNode>{};
  final _scroll = ScrollController();
  StreamSubscription<Duration>? _positions;
  Timer? _positionsTimer;

  /// The line sung now (as the saved edit would light it), -1 for none.
  int _sung = -1;

  /// The edit as it would show, made again when the rows change.
  Lyrics? _shown;

  LyricsEditor get _editor => widget.session.editor;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    _sung = _sungAt(widget.position());
    if (!_listen()) {
      _positionsTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
        if (_listen()) t.cancel();
      });
    }
  }

  bool _listen() {
    if (_positions != null) return true;
    final positions = widget.positions();
    if (positions == null) return false;
    _positions = positions.listen(_follow);
    return true;
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    unawaited(_positions?.cancel());
    _positionsTimer?.cancel();
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    _shown = null;
    // Rows gone (deleted, joined, undone) drop their fields.
    final ids = {for (final line in _editor.lines) line.id};
    for (final id in [..._fields.keys]) {
      if (!ids.contains(id)) _fields.remove(id)?.dispose();
    }
    for (final id in [..._focus.keys]) {
      if (!ids.contains(id)) _focus.remove(id)?.dispose();
    }
    if (mounted) setState(() {});
  }

  /// The row the saved edit would light at [at]; -1 when the song being
  /// edited is not the one playing.
  int _sungAt(Duration at) {
    if (!widget.songPlaying()) return -1;
    final shown = _shown ??= editForShow(_editor.result);
    return shown.lineAt(at.inMilliseconds + lyricsLeadMs);
  }

  void _follow(Duration at) {
    final line = _sungAt(at);
    if (line != _sung) setState(() => _sung = line);
  }

  TextEditingController _fieldOf(EditLine line) {
    final field = _fields.putIfAbsent(
      line.id,
      () => TextEditingController(text: line.text),
    );
    // Text changed elsewhere (undo, split, join): the field follows.
    if (field.text != line.text) {
      final at = field.selection.baseOffset.clamp(0, line.text.length);
      field.value = TextEditingValue(
        text: line.text,
        selection: TextSelection.collapsed(offset: at),
      );
    }
    return field;
  }

  FocusNode _focusOf(int id) => _focus.putIfAbsent(id, FocusNode.new);

  /// Puts the cursor in the row of [id] at [at], after this frame (the row
  /// may be new).
  void _focusRow(int id, int at) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _focus[id];
      final field = _fields[id];
      if (node == null || field == null) return;
      node.requestFocus();
      field.selection = TextSelection.collapsed(
        offset: at.clamp(0, field.text.length),
      );
    });
  }

  void _split(int index) {
    final line = _editor.lines[index];
    final field = _fields[line.id];
    final at = field?.selection.baseOffset ?? line.text.length;
    final next = _editor.split(index, at < 0 ? line.text.length : at);
    _focusRow(_editor.lines[next].id, 0);
  }

  KeyEventResult _rowKey(int id, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final index = _editor.indexOf(id);
    if (index < 0) return KeyEventResult.ignored;
    final field = _fields[id];
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace &&
        field != null &&
        field.selection.isCollapsed &&
        field.selection.baseOffset == 0 &&
        index > 0) {
      final aboveId = _editor.lines[index - 1].id;
      final at = _editor.joinUp(index);
      _focusRow(aboveId, at);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && index > 0) {
      _focusRow(_editor.lines[index - 1].id, field?.selection.baseOffset ?? 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown &&
        index < _editor.lines.length - 1) {
      _focusRow(_editor.lines[index + 1].id, field?.selection.baseOffset ?? 0);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int get _positionMs => widget.position().inMilliseconds;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // The field's own undo gives way to the editor's (a run of typing is
    // one step there): EditableText's undo and redo can be overridden.
    return Actions(
      actions: {
        UndoTextIntent: CallbackAction<UndoTextIntent>(
          onInvoke: (_) => session.textMode ? null : _editor.undo(),
        ),
        RedoTextIntent: CallbackAction<RedoTextIntent>(
          onInvoke: (_) => session.textMode ? null : _editor.redo(),
        ),
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < lyricsNarrowWidth;
          return session.textMode
              ? _textMode(context, narrow)
              : _rows(context, narrow);
        },
      ),
    );
  }

  Widget _caption(BuildContext context, String text, {Key? key}) => Text(
    text,
    key: key,
    style: TextStyle(color: OwnColors.of(context).dim2, fontSize: 13),
  );

  Widget _rows(BuildContext context, bool narrow) {
    final colors = OwnColors.of(context);
    final editor = _editor;
    final playing = widget.songPlaying();
    final lines = editor.lines;
    final side = narrow ? 8.0 : 32.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(side + 8, 10, 16, 6),
          child: !playing
              ? Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    _caption(
                      context,
                      'Play this song to time its lines.',
                      key: const ValueKey('lyrics-edit-not-playing'),
                    ),
                    TextButton.icon(
                      key: const ValueKey('lyrics-edit-play'),
                      onPressed: widget.onPlaySong,
                      icon: const Icon(Icons.play_arrow, size: 20),
                      label: const Text('Play it'),
                    ),
                  ],
                )
              : _caption(
                  context,
                  editor.tapping
                      ? 'Tap to time: press Space the moment the marked line '
                            'starts. Empty lines get a time too: there the '
                            'music plays without words.'
                      : 'Click a time to play from there. Enter splits a '
                            'line (at its end: a new line below), Backspace at '
                            'its start joins it to the line above. Ctrl+Z '
                            'undoes, Ctrl+S saves, F1 lists the keys.',
                  key: const ValueKey('lyrics-edit-help'),
                ),
        ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('lyrics-edit-rows'),
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(side, 0, 16, 24),
            itemCount: lines.length + 1,
            itemBuilder: (context, index) => index == lines.length
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(left: narrow ? 8 : 90, top: 8),
                      child: TextButton.icon(
                        key: const ValueKey('lyrics-edit-add'),
                        onPressed: () {
                          final at = editor.insertAt(lines.length);
                          _focusRow(editor.lines[at].id, 0);
                        },
                        icon: const Icon(Icons.add, size: 20),
                        label: const Text('Add line'),
                      ),
                    ),
                  )
                : _row(context, colors, index, narrow, playing),
          ),
        ),
        if (editor.tapping) _tapBar(context, narrow, playing),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    OwnColors colors,
    int index,
    bool narrow,
    bool playing,
  ) {
    final editor = _editor;
    final line = editor.lines[index];
    final note = editor.noteOf(index);
    final up = editor.tapping && index == editor.nextTap;
    final sung = index == _sung;
    final tapped = editor.tapped(line.id);
    final noteText = switch (note) {
      EditTimeNote.none => 'no time: lit with the line above',
      EditTimeNote.early => 'earlier than the line above',
      // In timed words an empty row without a time is only a gap; with
      // one the words go dark there (user, session 57: the break was not
      // obvious).
      EditTimeNote.fine
          when line.isBreak && line.startMs == null && editor.anyStart =>
        'a time makes it a music break',
      EditTimeNote.fine => null,
    };
    final noteColor = note == EditTimeNote.early
        ? Theme.of(context).colorScheme.error
        : colors.dim2;
    final timeColor = note == EditTimeNote.early
        ? Theme.of(context).colorScheme.error
        : tapped
        ? colors.accent
        : sung
        ? colors.text
        : colors.dim;
    final small = IconButton.styleFrom(
      minimumSize: const Size(32, 32),
      fixedSize: const Size(32, 32),
      padding: EdgeInsets.zero,
    );
    return Container(
      key: ValueKey('lyrics-edit-row-$index'),
      margin: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: up ? colors.raised : null,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 10,
            child: sung
                ? Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      shape: BoxShape.circle,
                    ),
                  )
                : null,
          ),
          SizedBox(
            width: narrow ? 64 : 76,
            child: TextButton(
              key: ValueKey('lyrics-edit-time-$index'),
              style: TextButton.styleFrom(
                foregroundColor: timeColor,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.centerRight,
              ),
              onPressed: line.startMs == null || !playing
                  ? (editor.tapping ? () => editor.tapFrom(index) : null)
                  : () {
                      if (editor.tapping) editor.tapFrom(index);
                      unawaited(
                        widget.seek(Duration(milliseconds: line.startMs!)),
                      );
                    },
              child: Text(
                up && editor.tapping ? 'next' : editTimeText(line.startMs),
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontSize: 14,
                ),
              ),
            ),
          ),
          if (!narrow) ...[
            IconButton(
              key: ValueKey('lyrics-edit-earlier-$index'),
              style: small,
              tooltip: 'Earlier by 0.1 s',
              onPressed: line.startMs == null
                  ? null
                  : () => editor.nudge(index, -editNudgeMs),
              icon: const Icon(Icons.remove, size: 16),
            ),
            IconButton(
              key: ValueKey('lyrics-edit-later-$index'),
              style: small,
              tooltip: 'Later by 0.1 s',
              onPressed: line.startMs == null
                  ? null
                  : () => editor.nudge(index, editNudgeMs),
              icon: const Icon(Icons.add, size: 16),
            ),
            IconButton(
              key: ValueKey('lyrics-edit-now-$index'),
              style: small,
              tooltip: 'Starts now',
              onPressed: playing
                  ? () => editor.setStart(index, _positionMs)
                  : null,
              icon: const Icon(Icons.my_location, size: 16),
            ),
          ],
          const SizedBox(width: 6),
          Expanded(child: _text(context, colors, line, index, narrow, sung)),
          if (noteText != null)
            narrow
                ? Tooltip(
                    message: noteText,
                    child: Icon(
                      note == EditTimeNote.early
                          ? Icons.error_outline
                          : Icons.schedule,
                      size: 16,
                      color: noteColor,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      noteText,
                      key: ValueKey('lyrics-edit-note-$index'),
                      style: TextStyle(color: noteColor, fontSize: 12),
                    ),
                  ),
          PopupMenuButton<void>(
            key: ValueKey('lyrics-edit-menu-$index'),
            tooltip: 'More for this line',
            icon: const Icon(Icons.more_horiz, size: 18),
            itemBuilder: (context) => [
              // A narrow place has no room for -, + and now in the row.
              if (narrow) ...[
                PopupMenuItem<void>(
                  enabled: line.startMs != null,
                  onTap: () => editor.nudge(index, -editNudgeMs),
                  child: const Text('Earlier by 0.1 s'),
                ),
                PopupMenuItem<void>(
                  enabled: line.startMs != null,
                  onTap: () => editor.nudge(index, editNudgeMs),
                  child: const Text('Later by 0.1 s'),
                ),
                PopupMenuItem<void>(
                  enabled: playing,
                  onTap: () => editor.setStart(index, _positionMs),
                  child: const Text('Starts now'),
                ),
                const PopupMenuDivider(),
              ],
              PopupMenuItem<void>(
                key: const ValueKey('lyrics-edit-insert-above'),
                onTap: () {
                  final at = editor.insertAt(index);
                  _focusRow(editor.lines[at].id, 0);
                },
                child: const Text('Insert a line above'),
              ),
              PopupMenuItem<void>(
                key: const ValueKey('lyrics-edit-insert-below'),
                onTap: () {
                  final at = editor.insertAt(index + 1);
                  _focusRow(editor.lines[at].id, 0);
                },
                child: const Text('Insert a line below'),
              ),
              // A music break is an empty row with a time: the words go
              // dark there. It starts now when this song plays past the
              // line; else it waits for a time (now, a tap).
              PopupMenuItem<void>(
                key: const ValueKey('lyrics-edit-insert-break'),
                onTap: () {
                  final now = _positionMs;
                  final start = line.startMs;
                  editor.insertAt(
                    index + 1,
                    startMs: playing && (start == null || now > start)
                        ? now
                        : null,
                  );
                },
                child: const Text('Insert a music break below'),
              ),
              PopupMenuItem<void>(
                enabled: line.startMs != null,
                onTap: () => editor.setStart(index, null),
                child: const Text('Remove its time'),
              ),
              PopupMenuItem<void>(
                onTap: () => editor.delete(index),
                child: const Text('Delete the line'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _text(
    BuildContext context,
    OwnColors colors,
    EditLine line,
    int index,
    bool narrow,
    bool sung,
  ) {
    final field = _fieldOf(line);
    final size = narrow ? 16.0 : 18.0;
    return Focus(
      onKeyEvent: (_, event) => _rowKey(line.id, event),
      child: TextField(
        key: ValueKey('lyrics-edit-field-$index'),
        controller: field,
        focusNode: _focusOf(line.id),
        readOnly: _editor.tapping,
        textInputAction: TextInputAction.next,
        onChanged: (text) {
          final at = _editor.indexOf(line.id);
          if (at >= 0) _editor.setText(at, text);
        },
        onSubmitted: (_) {
          final at = _editor.indexOf(line.id);
          if (at >= 0) _split(at);
        },
        style: TextStyle(
          color: sung ? colors.text : colors.text.withValues(alpha: 0.86),
          fontSize: size,
          fontWeight: sung ? FontWeight.w700 : FontWeight.w600,
          fontStyle: line.isBreak ? FontStyle.italic : null,
        ),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          // An empty row says which it is: a music break has a time; one
          // without is a gap between verses (its note says a time makes it
          // a break).
          hintText: line.text.isNotEmpty
              ? null
              : line.startMs != null
              ? '(music break)'
              : '(gap between verses)',
          hintStyle: TextStyle(
            color: colors.dim2,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w500,
            fontSize: size,
          ),
        ),
      ),
    );
  }

  Widget _tapBar(BuildContext context, bool narrow, bool playing) {
    final session = widget.session;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 48, 8, 16, 14),
      // The buttons, then the keys on their own line (the side panel
      // leaves too little width for both on one).
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const ValueKey('lyrics-edit-tap-now'),
                style: FilledButton.styleFrom(minimumSize: const Size(120, 52)),
                onPressed: playing && _editor.nextTap < _editor.lines.length
                    ? () => _editor.tap(_positionMs)
                    : null,
                icon: const Icon(Icons.touch_app),
                label: const Text('Tap'),
              ),
              FilterChip(
                key: const ValueKey('lyrics-edit-slower'),
                label: const Text('Slower 0.75x'),
                selected: session.slower,
                onSelected: session.setSlower,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_editor.nextTap >= _editor.lines.length)
            _caption(
              context,
              'Every line is timed. Done? Switch Tap to time off.',
            )
          else
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final (key, words) in tapKeys)
                  _keyHint(context, key, words),
              ],
            ),
        ],
      ),
    );
  }

  /// One key and what it does, as on the mockup: the key in a box.
  Widget _keyHint(BuildContext context, String key, String words) {
    final colors = OwnColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            border: Border.all(color: colors.dim2),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(key, style: TextStyle(color: colors.dim, fontSize: 12)),
        ),
        const SizedBox(width: 6),
        _caption(context, words),
      ],
    );
  }

  Widget _textMode(BuildContext context, bool narrow) {
    final session = widget.session;
    final controller = session.text!;
    final colors = OwnColors.of(context);
    final made = linesFromText(_editor.result, controller.text);
    final timed = made.kept + made.corrected;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 12 : 40, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _caption(
            context,
            'Fix words or paste whole lyrics here: one line per row, an empty '
            'row is a verse break. Lines you leave as they are or only correct '
            'keep their times; new lines have none until you tap or set them.',
          ),
          const SizedBox(height: 10),
          Expanded(
            child: TextField(
              key: const ValueKey('lyrics-edit-textbox'),
              controller: controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                color: colors.text,
                fontSize: narrow ? 16 : 18,
                height: 1.55,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: colors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _caption(
            context,
            '${made.lines.where((line) => !line.isGap).length} lines: '
            '$timed keep a time${made.corrected > 0 ? ' (${made.corrected} '
                      'corrected)' : ''}, ${made.added} new without one.',
            key: const ValueKey('lyrics-edit-count'),
          ),
        ],
      ),
    );
  }
}
