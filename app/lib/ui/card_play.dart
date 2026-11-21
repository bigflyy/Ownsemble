import 'package:flutter/material.dart';

import 'playing_mark.dart' show NowPlaying, PlayingMark;
import 'theme.dart';

/// A card's Play: the `PlayedFrom.key` its list plays under, and what
/// starts it.
typedef CardPlay = ({String key, Future<void> Function() onPlay});

/// Tells the [CardPlayButton] inside whether its card is pointed at or has
/// the keyboard focus. Wrap the whole card (cover, title and line) in it.
class CardHover extends StatefulWidget {
  const CardHover({super.key, required this.child});

  final Widget child;

  /// Whether the card around [context] is pointed at or focused; false
  /// outside a card.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CardHoverScope>()?.shown ??
      false;

  @override
  State<CardHover> createState() => _CardHoverState();
}

class _CardHoverState extends State<CardHover> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    // Not a stop of its own: it only hears when the card's own button or
    // link inside takes the focus.
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: _CardHoverScope(shown: _hovered || _focused, child: widget.child),
    ),
  );
}

class _CardHoverScope extends InheritedWidget {
  const _CardHoverScope({required this.shown, required super.child});

  final bool shown;

  @override
  bool updateShouldNotify(_CardHoverScope oldWidget) =>
      shown != oldWidget.shown;
}

/// The Play of a cover card (For you and playlist cards, album and release
/// cards on an artist page), the look the user picked on 2026-11-21 (board
/// A, as Spotify's on a computer): a solid accent circle at the cover's
/// bottom right, shown only while the card is pointed at or focused, so the
/// cover stays clean. The card whose list plays keeps it: moving bars, Pause
/// while pointed at, Play while paused; a click then pauses or resumes
/// instead of starting over. With no mouse (a
/// phone) it shows only on the playing card: a tap opens the card.
class CardPlayButton extends StatefulWidget {
  const CardPlayButton({
    super.key,
    required this.state,
    required this.onPlay,
    this.size = 40,
  });

  /// [NowPlaying.listStateFor] of the card's list: null when it does not
  /// play, else whether sound plays.
  final bool? state;

  /// Starts the card's list; null when it has nothing to play. While its
  /// future runs (an album's list asked from VK, the first song starting)
  /// the circle shows a spinner, so the click is seen at once.
  final Future<void> Function()? onPlay;
  final double size;

  @override
  State<CardPlayButton> createState() => _CardPlayButtonState();
}

class _CardPlayButtonState extends State<CardPlayButton> {
  var _busy = false;

  Future<void> _press() async {
    if (widget.state != null && NowPlaying.playOrPause(context)) return;
    final onPlay = widget.onPlay;
    if (onPlay == null || _busy) return;
    setState(() => _busy = true);
    try {
      await onPlay();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final state = widget.state;
    final pointed = CardHover.of(context);
    final shown = pointed || state != null || _busy;
    // While its list plays the circle shows moving bars, as the playing
    // row's thumbnail does; pointed at, it says what a click does: Pause
    // (user, 2026-11-21).
    final bars = state == true && !pointed;
    final playing = state == true;
    final size = widget.size;
    const duration = Duration(milliseconds: 150);
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: duration,
        child: AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(0, 0.15),
          duration: duration,
          curve: Curves.easeOut,
          child: Tooltip(
            message: playing ? 'Pause' : 'Play',
            child: Material(
              color: colors.accent,
              shape: const CircleBorder(),
              elevation: 4,
              shadowColor: Colors.black,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onPlay == null && state == null ? null : _press,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: _busy && state == null
                      ? Padding(
                          padding: EdgeInsets.all(size * 0.28),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.onAccent,
                          ),
                        )
                      : bars
                      ? Center(
                          child: PlayingMark(
                            playing: true,
                            size: size * 0.42,
                            color: colors.onAccent,
                          ),
                        )
                      : Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          color: colors.onAccent,
                          size: size * 0.6,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
