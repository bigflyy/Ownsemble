/// Plan 10 I2g4: the lyrics editor in the release app, on real songs of the
/// test account, muted, with the audio decoded.
///
/// Two runs on one data folder, so a restart lies between them:
/// - [EditLiveBench.before] (part editLive): a song with found timed lyrics
///   is edited the way the user does it: words typed, a line split with
///   Enter and two joined with Backspace (real Windows key messages, sent by
///   tool/edit_live_check.dart), times nudged with - and +, a music break
///   inserted from the row's menu while the song plays past the row, lines
///   tapped with Space at real positions (Left and Down too); saved; edited
///   again as text, saved, the toast's Undo, saved again. A song with heard
///   words is edited and saved too.
/// - [EditLiveBench.after] (part editLiveAfter): both edits show after the
///   restart, unchanged (digests of the lines, no words in the result);
///   Undo the last save, Back to the source and Use again, a refresh of
///   every source, and a version switch (another upload has its own lyrics;
///   back to the song's own upload the edit shows again).
///
/// The keys come from the tool: the bench writes what to press to the
/// result file's name + ".ready" and waits for its name + ".go". Results hold numbers,
/// sources and yes/no only, never words.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../library/track.dart';
import '../lyrics/heard_lyrics.dart' show heardSource;
import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_edit.dart';
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../ui/library_controller.dart';
import '../ui/lyrics_edit_page.dart';

/// Typed into the found song's line 2 (Cyrillic: the round trip).
const editLiveFoundWords = ' правка';

/// Typed at the end of the heard song's first line.
const editLiveHeardWords = ' да';

/// The line the text mode changes gets this at its end.
const editLiveTextWords = ' (2)';

class EditLiveBench {
  EditLiveBench({
    required this.library,
    required this.player,
    required this.playback,
    required this.lyrics,
    required this.keys,
    required this.resultFile,
  });

  final LibraryController library;
  final PlayerService player;
  final PlaybackController playback;
  final LyricsController lyrics;

  /// The found song's and the heard song's library keys (ownerId_audioId).
  final List<String> keys;
  final String resultFile;

  // ---- The first run -----------------------------------------------------

  Future<Map<String, Object?>> before() async {
    final result = <String, Object?>{};
    if (keys.length != 2) return {'error': 'give 2 keys: found,heard'};
    final found = _songOf(keys[0]);
    final heard = _songOf(keys[1]);
    if (found == null || heard == null) {
      return {'error': 'a key is not in the library'};
    }
    try {
      result['found'] = await _editFound(found);
      result['heard'] = await _editHeard(heard);
    } on Object catch (error, stack) {
      result['error'] = '$error';
      result['at'] = '$stack'.split('\n').take(4).join(' | ');
    }
    await player.stop();
    return result;
  }

  /// The section running, for [_pauses].
  String _section = 'start';

  /// Every change of playing while the first run edits: in which section.
  final _pauses = <String>[];

  Future<Map<String, Object?>> _editFound(Track song) async {
    final r = <String, Object?>{'seconds': song.durationSec};
    void watch() =>
        _pauses.add('$_section:${player.playing.value ? 'play' : 'pause'}');
    player.playing.addListener(watch);
    try {
      return await _editFoundSteps(song, r);
    } finally {
      player.playing.removeListener(watch);
      r['playingChanges'] = _pauses;
    }
  }

  Future<Map<String, Object?>> _editFoundSteps(
    Track song,
    Map<String, Object?> r,
  ) async {
    r['play'] = await _play(song);
    _openLyricsPlace();
    final ready = await _until(
      () => switch (lyrics.state) {
        LyricsShown(:final lyrics, :final refreshing) =>
          !refreshing && lyrics.timed,
        _ => false,
      },
      const Duration(seconds: 60),
    );
    final shown = lyrics.state;
    r['shownBefore'] = _stateOf(shown);
    if (!ready || shown is! LyricsShown) {
      return r..['error'] = 'no timed lyrics';
    }
    final base = shown.lyrics.source;
    final shownLines = shown.lyrics.lines.length;

    // Open the editor through the heading's Edit button.
    _section = 'open';
    await _pressOrThrow('lyrics-edit');
    await _frames();
    var session = _session();
    if (session == null) return r..['error'] = 'no editor';
    final editor = session.editor;
    r['open'] = {
      'lines': editor.lines.length,
      'shownLines': shownLines,
      'timed': editor.lines.where((l) => l.startMs != null).length,
      'basedOn': session.basedOn,
      'holdSong': playback.holdSong,
      'songPlaying': _editedSongPlaying(session),
      'placeWidth': _widthOf<LyricsEditPage>(),
    };
    final opened = [for (final line in editor.lines) line.text];
    // Sung rows (with words) near the top, all on screen.
    final sung = [
      for (var i = 0; i < editor.lines.length && i < 12; i++)
        if (!editor.lines[i].isBreak && editor.lines[i].startMs != null) i,
    ];
    if (sung.length < 8) return r..['error'] = 'too few sung lines on top';

    // 1. Words: the cursor at the end of a line, typed letters.
    _section = 'type';
    final typeRow = sung[1];
    await _focusField(typeRow, atEnd: true);
    await _keys([
      {'type': editLiveFoundWords},
    ]);
    r['typed'] = {
      'row': typeRow,
      'textEndsWithTyped': editor.lines[typeRow].text.endsWith(
        editLiveFoundWords,
      ),
      'grewBy': editor.lines[typeRow].text.length - opened[typeRow].length,
      'typedLength': editLiveFoundWords.length,
      ..._added(opened[typeRow], editor.lines[typeRow].text),
    };

    // 2. Split with Enter in the middle of a line (at a space).
    _section = 'split';
    final splitRow = sung[3];
    final splitText = editor.lines[splitRow].text;
    final splitStart = editor.lines[splitRow].startMs;
    final splitAt = _middleSpace(splitText);
    final countBeforeSplit = editor.lines.length;
    await _focusField(splitRow, at: splitAt);
    await _keys([
      {'key': 'enter'},
    ]);
    r['split'] = {
      'row': splitRow,
      'at': splitAt,
      'linesAdded': editor.lines.length - countBeforeSplit,
      'firstPartKept':
          editor.lines[splitRow].text == splitText.substring(0, splitAt),
      'firstKeptTime': editor.lines[splitRow].startMs == splitStart,
      'newLineUntimed': editor.lines[splitRow + 1].startMs == null,
      'newLineIsRest':
          editor.lines[splitRow + 1].text.trim() ==
          splitText.substring(splitAt).trim(),
      'noteOfNew': editor.noteOf(splitRow + 1).name,
    };

    // 3. Join with Backspace at the start of a line (two rows further).
    _section = 'join';
    final joinRow = sung[6] + 1; // +1: the split added a row above.
    final aboveText = editor.lines[joinRow - 1].text;
    final aboveStart = editor.lines[joinRow - 1].startMs;
    final joinedText = editor.lines[joinRow].text;
    final countBeforeJoin = editor.lines.length;
    await _focusField(joinRow, at: 0);
    await _keys([
      {'key': 'back'},
    ]);
    final joined = editor.lines[joinRow - 1].text;
    r['join'] = {
      'row': joinRow,
      'linesRemoved': countBeforeJoin - editor.lines.length,
      'textJoined':
          joined.startsWith(aboveText.trimRight()) &&
          joined.endsWith(joinedText.trimLeft()),
      'aboveKeptTime': editor.lines[joinRow - 1].startMs == aboveStart,
    };
    FocusManager.instance.primaryFocus?.unfocus();
    await _frames();

    // 4. Nudge: + twice on the first sung row, - once on the next.
    _section = 'nudge';
    final nudgeA = sung[0];
    final nudgeB = sung[1];
    final startA = editor.lines[nudgeA].startMs!;
    final startB = editor.lines[nudgeB].startMs!;
    Future<bool> nudge(int row, String way) async =>
        await _press('lyrics-edit-$way-$row') ||
        (await _openMenu('lyrics-edit-menu-$row') &&
            await _press('lyrics-edit-menu-$way'));
    final pressedNudges = [
      await nudge(nudgeA, 'later'),
      await nudge(nudgeA, 'later'),
      await nudge(nudgeB, 'earlier'),
    ];
    r['nudge'] = {
      'pressed': pressedNudges,
      'deltaA': editor.lines[nudgeA].startMs! - startA,
      'deltaB': editor.lines[nudgeB].startMs! - startB,
    };

    // 5. A music break below a row the song has played past.
    _section = 'break';
    final breakRow = sung[2];
    final breakAbove = editor.lines[breakRow].startMs!;
    await playback.seek(Duration(milliseconds: breakAbove + 1500));
    await _until(
      () => player.position.inMilliseconds > breakAbove + 1000,
      const Duration(seconds: 10),
    );
    final countBeforeBreak = editor.lines.length;
    final atPress = player.position.inMilliseconds;
    final menuOpened = await _openMenu('lyrics-edit-menu-$breakRow');
    final breakPressed = await _press('lyrics-edit-insert-break');
    await _frames();
    final newBreak = editor.lines[breakRow + 1];
    r['musicBreak'] = {
      'menuOpened': menuOpened,
      'pressed': breakPressed,
      'linesAdded': editor.lines.length - countBeforeBreak,
      'isBreak': newBreak.isBreak,
      'timed': newBreak.startMs != null,
      'msFromPosition': newBreak.startMs == null
          ? null
          : newBreak.startMs! - atPress,
      'afterAbove': (newBreak.startMs ?? 0) > breakAbove,
    };

    // 6. Tap to time from a row further down, with real Space, Left, Down.
    _section = 'tap';
    final tapRow = [
      for (var i = sung[5] + 2; i < editor.lines.length && i < 14; i++)
        if (!editor.lines[i].isBreak) i,
    ].first;
    final tapOn = await _press('lyrics-edit-tap');
    await _frames();
    // The row's time button starts tapping there and plays from its start.
    final fromPressed = await _press('lyrics-edit-time-$tapRow');
    await _frames();
    final nextAfterFrom = editor.nextTap;
    // Each change of the editor: a row whose start changed then was set
    // to the player's position at that moment (Space sets "now").
    var startsBefore = [for (final line in editor.lines) line.startMs];
    var changes = 0;
    final tapDiffs = <int>[];
    void noteChange() {
      changes++;
      final now = player.position.inMilliseconds;
      final starts = [for (final line in editor.lines) line.startMs];
      if (starts.length == startsBefore.length) {
        for (var i = 0; i < starts.length; i++) {
          if (starts[i] != startsBefore[i] && starts[i] != null) {
            tapDiffs.add((starts[i]! - now).abs());
          }
        }
      }
      startsBefore = starts;
    }

    editor.addListener(noteChange);
    final playingBeforeTaps = player.playing.value;
    final playingChanges = <bool>[];
    void notePlaying() => playingChanges.add(player.playing.value);
    player.playing.addListener(notePlaying);
    final tapStartMs = player.position.inMilliseconds;
    await _keys([
      {'key': 'space'},
      {'wait': 1500},
      {'key': 'space'},
      {'wait': 1500},
      {'key': 'left'},
      {'wait': 400},
      {'key': 'space'},
      {'wait': 1200},
      {'key': 'down'},
      {'wait': 400},
      {'key': 'space'},
    ]);
    editor.removeListener(noteChange);
    player.playing.removeListener(notePlaying);
    final tapped = [
      for (var i = 0; i < editor.lines.length; i++)
        if (editor.tapped(editor.lines[i].id)) i,
    ];
    final tappedStarts = [for (final i in tapped) editor.lines[i].startMs!];
    r['tap'] = {
      'switchPressed': tapOn,
      'timePressed': fromPressed,
      'row': tapRow,
      'nextAfterTimeButton': nextAfterFrom,
      'changes': changes,
      'timesSet': tapDiffs.length,
      'tappedRows': tapped,
      'tappedInOrder': _rising(tappedStarts),
      // Taps 1.5 s and more apart while the song plays: starts as far apart.
      'tappedGapsMs': [
        for (var i = 1; i < tappedStarts.length; i++)
          tappedStarts[i] - tappedStarts[i - 1],
      ],
      'firstTapAfterStart':
          tappedStarts.isNotEmpty && tappedStarts.first >= tapStartMs - 100,
      'maxMsFromPosition': tapDiffs.isEmpty
          ? null
          : tapDiffs.reduce((a, b) => a > b ? a : b),
      'stillPlaying': player.playing.value,
      'playingBeforeTaps': playingBeforeTaps,
      'playingChanges': playingChanges,
      'rate': player.player.state.rate,
    };
    await _press('lyrics-edit-tap');
    await _frames();

    // 7. Save.
    _section = 'save';
    final toSave = editor.result;
    final saved1 = _digest(toSave);
    await _pressOrThrow('lyrics-edit-save');
    await _frames();
    final after1 = lyrics.state;
    r['save1'] = {
      ..._editFacts(),
      'shown': _stateOf(after1),
      'digest': saved1,
      'storedSame': _digest(lyrics.edit?.lines ?? const []) == saved1,
      'lines': toSave.length,
      'editorClosed': _session() == null,
      'holdSong': playback.holdSong,
      'toast': _find('lyrics-edit-saved') != null,
      'lineAtNow': after1 is LyricsShown
          ? after1.lyrics.lineAt(player.position.inMilliseconds)
          : null,
    };

    // 8. Edit again, as text: a line changed, saved.
    await _openMenu('lyrics-edited');
    await _pressOrThrow('lyrics-edit-again');
    await _frames();
    session = _session();
    if (session == null) return r..['error'] = 'no editor again';
    await _pressOrThrow('lyrics-edit-text');
    await _frames();
    final box = session.text!;
    final rows = box.text.split('\n');
    final textRow = sung[4] + 1;
    rows[textRow] = '${rows[textRow]}$editLiveTextWords';
    box.text = rows.join('\n');
    await _frames();
    final countText = _textOf('lyrics-edit-count');
    final keptMatch = RegExp(r'(\d+) lines: (\d+) keep')
        .firstMatch(countText ?? '');
    await _press('lyrics-edit-text');
    await _frames();
    final secondLines = session.editor.result;
    final saved2 = _digest(secondLines);
    r['asText'] = {
      'row': textRow,
      'countShown': keptMatch != null,
      'lines': keptMatch == null ? null : int.parse(keptMatch.group(1)!),
      'keepTime': keptMatch == null ? null : int.parse(keptMatch.group(2)!),
      'changedRowKeptTime':
          secondLines[textRow].startMs == toSave[textRow].startMs,
      'changedRowText': secondLines[textRow].text.endsWith(editLiveTextWords),
      'otherLinesSame': [
        for (var i = 0; i < secondLines.length; i++)
          if (i != textRow) secondLines[i].text == toSave[i].text,
      ].every((same) => same),
    };
    await _pressOrThrow('lyrics-edit-save');
    await _frames();
    r['save2'] = {..._editFacts(), 'digest': saved2};

    // 9. The toast's Undo, then the same save again.
    final undone = await _press('lyrics-edit-saved');
    await _frames();
    r['toastUndo'] = {
      'pressed': undone,
      ..._editFacts(),
      'backToFirst': _digest(lyrics.edit?.lines ?? const []) == saved1,
    };
    await _openMenu('lyrics-edited');
    await _pressOrThrow('lyrics-edit-again');
    await _frames();
    session = _session()!;
    await _pressOrThrow('lyrics-edit-text');
    await _frames();
    final again = session.text!;
    final againRows = again.text.split('\n');
    againRows[textRow] = '${againRows[textRow]}$editLiveTextWords';
    again.text = againRows.join('\n');
    await _frames();
    await _pressOrThrow('lyrics-edit-save');
    await _frames();
    r['save3'] = {
      ..._editFacts(),
      'sameAsSecond': _digest(lyrics.edit?.lines ?? const []) == saved2,
    };
    r['digests'] = {'first': saved1, 'second': saved2};
    r['basedOn'] = base;
    r['routeKeyIsOwn'] = lyrics.routeKeyOf(song) == song.sourceKey;
    return r;
  }

  Future<Map<String, Object?>> _editHeard(Track song) async {
    final r = <String, Object?>{'seconds': song.durationSec};
    r['play'] = await _play(song);
    _openLyricsPlace();
    await _until(
      () => switch (lyrics.state) {
        LyricsShown(:final lyrics, :final refreshing) =>
          !refreshing && lyrics.source == heardSource,
        LyricsMissing() => true,
        _ => false,
      },
      const Duration(seconds: 60),
    );
    final shown = lyrics.state;
    r['shownBefore'] = _stateOf(shown);
    if (shown is! LyricsShown || shown.lyrics.source != heardSource) {
      return r..['error'] = 'no heard words';
    }
    await _pressOrThrow('lyrics-edit');
    await _frames();
    final session = _session();
    if (session == null) return r..['error'] = 'no editor';
    final editor = session.editor;
    r['open'] = {
      'lines': editor.lines.length,
      'timed': editor.lines.where((l) => l.startMs != null).length,
      'basedOn': session.basedOn,
    };
    final row = [
      for (var i = 0; i < editor.lines.length; i++)
        if (!editor.lines[i].isBreak) i,
    ].first;
    await _focusField(row, atEnd: true);
    final before = editor.lines[row].text;
    await _keys([
      {'chars': editLiveHeardWords},
    ]);
    r['typed'] = editor.lines[row].text.endsWith(editLiveHeardWords);
    r['typedHow'] = _added(before, editor.lines[row].text);
    FocusManager.instance.primaryFocus?.unfocus();
    final digest = _digest(editor.result);
    await _pressOrThrow('lyrics-edit-save');
    await _frames();
    r['save'] = {
      ..._editFacts(),
      'shown': _stateOf(lyrics.state),
      'digest': digest,
      'storedSame': _digest(lyrics.edit?.lines ?? const []) == digest,
    };
    return r;
  }

  // ---- The second run, after the restart ----------------------------------

  Future<Map<String, Object?>> after() async {
    final result = <String, Object?>{};
    if (keys.length != 2) return {'error': 'give 2 keys: found,heard'};
    final found = _songOf(keys[0]);
    final heard = _songOf(keys[1]);
    if (found == null || heard == null) {
      return {'error': 'a key is not in the library'};
    }
    try {
      result['found'] = await _afterFound(found);
      result['heard'] = await _afterHeard(heard);
    } on Object catch (error, stack) {
      result['error'] = '$error';
      result['at'] = '$stack'.split('\n').take(4).join(' | ');
    }
    await player.stop();
    return result;
  }

  Future<Map<String, Object?>> _afterFound(Track song) async {
    final r = <String, Object?>{};
    r['play'] = await _play(song);
    _openLyricsPlace();
    await _until(_edited, const Duration(seconds: 30));
    r['afterRestart'] = {
      ..._editFacts(),
      'shown': _stateOf(lyrics.state),
      'digest': _digest(lyrics.edit?.lines ?? const []),
      'cyrillicKept':
          lyrics.edit?.lines.any(
            (line) => line.text.contains(editLiveFoundWords.trim()),
          ) ??
          false,
      'lineAtNow': switch (lyrics.state) {
        LyricsShown(:final lyrics) => lyrics.lineAt(
          player.position.inMilliseconds,
        ),
        _ => null,
      },
    };

    // Undo the last save from the Edited menu.
    final menu = await _openMenu('lyrics-edited');
    final undo = await _press('lyrics-undo-save');
    await _frames();
    r['undo'] = {
      'menuOpened': menu,
      'pressed': undo,
      ..._editFacts(),
      'shown': _stateOf(lyrics.state),
      'digest': _digest(lyrics.edit?.lines ?? const []),
    };

    // Back to the source, then Use the edit again (the chooser's row).
    final base = lyrics.edit?.basedOn;
    await _openMenu('lyrics-edited');
    final back = await _press('lyrics-show-original');
    await _frames();
    r['backToSource'] = {
      'pressed': back,
      'basedOn': base,
      'shown': _stateOf(lyrics.state),
      'editKept': lyrics.edit != null,
    };
    lyrics.use(editedSource);
    await _frames();
    r['useEditAgain'] = {'shown': _stateOf(lyrics.state)};

    // Every source asked again: the edit still shows.
    final refreshClock = Stopwatch()..start();
    await lyrics.askAll(again: true);
    lyrics.show(song, again: true);
    await _frames();
    r['refresh'] = {
      'ms': refreshClock.elapsedMilliseconds,
      'found': [
        for (final choice in lyrics.choices)
          if (choice.status == LyricsChoiceStatus.found) choice.source,
      ],
      'failed': [
        for (final choice in lyrics.choices)
          if (choice.status == LyricsChoiceStatus.failed) choice.source,
      ],
      'shown': _stateOf(lyrics.state),
      ..._editFacts(),
    };

    // A version switch: another upload has its own lyrics.
    r['version'] = await _versionSwitch(song);
    return r;
  }

  Future<Map<String, Object?>> _versionSwitch(Track song) async {
    final r = <String, Object?>{};
    final versions = player.versions;
    final routes = player.ownRoutesFor(song);
    if (versions == null || routes.isEmpty) return {'error': 'no route'};
    final own = routes.first;
    final list = versions.listOf(song, own, refresh: true);
    await _until(() => !list.searching, const Duration(seconds: 120));
    final other = list.uploads
        .where((v) => v.key != own.sourceKey && !v.isCurrentFile)
        .firstOrNull;
    r['uploadsFound'] = list.uploads.length;
    if (other == null) return r..['error'] = 'no other upload';
    versions.pick(song, other);
    // As the version menu's Use does: the playing song plays it at once.
    await playback.versionChanged(song);
    r['playOther'] = await _playing();
    await _until(
      () => switch (lyrics.state) {
        LyricsShown(:final refreshing) => !refreshing,
        LyricsMissing() || LyricsFailed() => true,
        _ => false,
      },
      const Duration(seconds: 60),
    );
    r['other'] = {
      'routeIsOther': lyrics.routeKeyOf(song) == other.key,
      'shown': _stateOf(lyrics.state),
      'editShown': _edited(),
      'editOfThisUpload': lyrics.edit != null,
    };
    versions.reset(song);
    await playback.versionChanged(song);
    r['playOwn'] = await _playing();
    await _until(_edited, const Duration(seconds: 30));
    r['own'] = {
      'routeIsOwn': lyrics.routeKeyOf(song) == own.sourceKey,
      'shown': _stateOf(lyrics.state),
      ..._editFacts(),
      'digest': _digest(lyrics.edit?.lines ?? const []),
    };
    return r;
  }

  Future<Map<String, Object?>> _afterHeard(Track song) async {
    final r = <String, Object?>{};
    r['play'] = await _play(song);
    _openLyricsPlace();
    await _until(_edited, const Duration(seconds: 30));
    r['afterRestart'] = {
      ..._editFacts(),
      'shown': _stateOf(lyrics.state),
      'digest': _digest(lyrics.edit?.lines ?? const []),
      'cyrillicKept':
          lyrics.edit?.lines.any(
            (line) => line.text.endsWith(editLiveHeardWords),
          ) ??
          false,
    };
    await _openMenu('lyrics-edited');
    final back = await _press('lyrics-show-original');
    await _frames();
    r['backToHeard'] = {
      'pressed': back,
      'shown': _stateOf(lyrics.state),
      'editKept': lyrics.edit != null,
    };
    // The automatic pick takes the edit first.
    lyrics.useAutomatic();
    await _frames();
    r['automatic'] = {'shown': _stateOf(lyrics.state)};
    return r;
  }

  // ---- Helpers -------------------------------------------------------------

  Track? _songOf(String key) =>
      library.all.where((t) => t.sourceKey == key && t.inLibrary).firstOrNull;

  bool _edited() => switch (lyrics.state) {
    LyricsShown(:final lyrics) => lyrics.source == editedSource,
    _ => false,
  };

  Map<String, Object?> _editFacts() {
    final edit = lyrics.edit;
    return {
      'saves': edit?.saves ?? 0,
      'editBasedOn': edit?.basedOn,
      'shownSource': lyrics.shownSource,
    };
  }

  static Map<String, Object?> _stateOf(LyricsState state) => switch (state) {
    LyricsShown(:final lyrics, :final refreshing) => {
      'state': 'shown',
      'source': lyrics.source,
      'timed': lyrics.timed,
      'lines': lyrics.lines.length,
      'passed': lyrics.lines.where((l) => l.passed).length,
      'refreshing': refreshing,
    },
    _ => {'state': '${state.runtimeType}'},
  };

  /// A short digest of lines (texts and starts): equal lines, equal digest.
  static String _digest(List<LyricLine> lines) => sha1
      .convert(
        utf8.encode(
          jsonEncode([
            for (final line in lines) [line.text, line.startMs],
          ]),
        ),
      )
      .toString()
      .substring(0, 12);

  static bool _rising(List<int> values) {
    for (var i = 1; i < values.length; i++) {
      if (values[i] < values[i - 1]) return false;
    }
    return true;
  }

  /// A space near the middle of [text] (its middle when it has none).
  static int _middleSpace(String text) {
    final middle = text.length ~/ 2;
    var best = -1;
    for (var i = 1; i < text.length - 1; i++) {
      if (text[i] != ' ') continue;
      if (best < 0 || (i - middle).abs() < (best - middle).abs()) best = i;
    }
    return best < 0 ? middle : best;
  }

  Future<Map<String, Object?>> _play(Track song) async {
    final timing = await playback.playFrom([song], 0);
    return {
      'ok': timing?.ok,
      'sampleRate': timing?.sampleRate,
      'stillPlayingAfter1s': await _keepsPlaying(),
    };
  }

  /// The song now playing: loaded and going on.
  Future<Map<String, Object?>> _playing() async => {
    'ok': player.currentLoaded,
    'stillPlayingAfter1s': await _keepsPlaying(),
  };

  /// What typing added to [before], by kind of letter: no words.
  static Map<String, Object?> _added(String before, String after) {
    final added = after.startsWith(before)
        ? after.substring(before.length)
        : null;
    if (added == null) return {'addedAtEnd': false};
    return {
      'addedAtEnd': true,
      'added': added.length,
      'latin': RegExp('[A-Za-z]').allMatches(added).length,
      'cyrillic': RegExp('[Ѐ-ӿ]').allMatches(added).length,
      'spaces': ' '.allMatches(added).length,
    };
  }

  /// The width of the first widget of type [T] on screen.
  static double? _widthOf<T extends Widget>() {
    double? width;
    void visit(Element element) {
      if (width != null) return;
      if (element.widget is T) {
        width = element.size?.width;
        return;
      }
      element.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(visit);
    return width;
  }

  Future<bool> _keepsPlaying() async {
    try {
      await player.player.stream.position
          .firstWhere((position) => position >= const Duration(seconds: 1))
          .timeout(const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return player.player.state.position >= const Duration(seconds: 1);
    } on StateError {
      return false;
    }
  }

  void _openLyricsPlace() {
    if (!library.view.showsLyrics) library.toggleLyrics();
  }

  bool _editedSongPlaying(LyricsEditSession session) {
    final current = player.current;
    return current != null &&
        current.id == session.track.id &&
        lyrics.routeKeyOf(current) == session.uploadKey;
  }

  /// Waits until [condition] or [limit]; false on the limit.
  static Future<bool> _until(bool Function() condition, Duration limit) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > limit) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  static Future<void> _frames() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await WidgetsBinding.instance.endOfFrame;
  }

  static Element? _find(String key) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == ValueKey(key)) {
        found = element;
        return;
      }
      element.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(visit);
    return found;
  }

  LyricsEditSession? _session() {
    LyricsEditSession? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is LyricsEditPage) {
        found = widget.session;
        return;
      }
      element.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(visit);
    return found;
  }

  /// Calls what a click on the widget keyed [key] calls: the button's
  /// onPressed, or the tap handler under it. False when there is none.
  Future<bool> _press(String key) async {
    final element = _find(key);
    if (element == null) return false;
    VoidCallback? action;
    void look(Element e) {
      if (action != null) return;
      final widget = e.widget;
      action = switch (widget) {
        ButtonStyleButton(:final onPressed) => onPressed,
        IconButton(:final onPressed) => onPressed,
        InkWell(:final onTap) => onTap,
        GestureDetector(:final onTap) => onTap,
        _ => null,
      };
      if (action == null) e.visitChildElements(look);
    }

    look(element);
    final pressed = action;
    if (pressed == null) return false;
    pressed();
    await _frames();
    return true;
  }

  Future<void> _pressOrThrow(String key) async {
    if (!await _press(key)) throw StateError('nothing to press at $key');
  }

  /// Opens the popup menu keyed [key], as a click on it does.
  Future<bool> _openMenu(String key) async {
    final element = _find(key);
    if (element is! StatefulElement) return false;
    final state = element.state;
    if (state is! PopupMenuButtonState) return false;
    state.showButtonMenu();
    await _frames();
    return true;
  }

  String? _textOf(String key) {
    final element = _find(key);
    final widget = element?.widget;
    return widget is Text
        ? (widget.data ?? widget.textSpan?.toPlainText())
        : null;
  }

  /// Puts the cursor in row [row]'s field: at its end or at [at].
  Future<void> _focusField(int row, {bool atEnd = false, int at = 0}) async {
    final element = _find('lyrics-edit-field-$row');
    final field = element?.widget;
    if (field is! TextField) throw StateError('no field in row $row');
    field.focusNode!.requestFocus();
    await _frames();
    final controller = field.controller!;
    controller.selection = TextSelection.collapsed(
      offset: atEnd ? controller.text.length : at,
    );
    await _frames();
  }

  /// Asks the tool for real key messages and waits until they are sent.
  Future<void> _keys(List<Map<String, Object>> steps) async {
    final ready = File('$resultFile.ready');
    final go = File('$resultFile.go');
    if (go.existsSync()) go.deleteSync();
    ready.writeAsStringSync(jsonEncode(steps));
    final sent = await _until(go.existsSync, const Duration(seconds: 60));
    if (!sent) throw StateError('the tool sent no keys');
    go.deleteSync();
    await _frames();
  }
}
