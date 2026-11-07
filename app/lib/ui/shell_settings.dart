import 'package:flutter/foundation.dart';

/// Where the player sits: the side panel or the bottom bar (the bar is
/// also used whenever the window is too narrow for the panel).
enum PlayerDock { side, bottom }

/// How calendars (the Custom period's month tiles and days) show how much
/// was heard: a line under each (the default), a green tint, or not at all
/// (the user, 2026-11-07: "i like the line and color").
enum CalendarListening { line, color, off }

/// Look and layout choices of the window, kept between runs.
class ShellSettings extends ChangeNotifier {
  ShellSettings({
    required String? Function(String key) read,
    required this._write,
  }) {
    _dark = read(_themeKey) != 'light';
    _thumbnails = read(_thumbsKey) != 'off';
    _rail = read(_railKey) == 'on';
    _dock = read(_dockKey) == 'bottom' ? PlayerDock.bottom : PlayerDock.side;
    _calendar =
        CalendarListening.values.asNameMap()[read(_calendarKey)] ??
        CalendarListening.line;
  }

  /// Settings that are not stored anywhere (tests).
  ShellSettings.inMemory() : this(read: (_) => null, write: (_, _) {});

  static const _themeKey = 'ui.theme';
  static const _thumbsKey = 'ui.thumbnails';
  static const _railKey = 'ui.rail';
  static const _dockKey = 'ui.dock';
  static const _calendarKey = 'ui.calendar_listening';

  final void Function(String key, String? value) _write;
  late bool _dark;
  late bool _thumbnails;
  late bool _rail;
  late PlayerDock _dock;
  late CalendarListening _calendar;

  /// Listening in calendars: line, color or off.
  CalendarListening get calendarListening => _calendar;

  void setCalendarListening(CalendarListening value) {
    if (value == _calendar) return;
    _calendar = value;
    _write(_calendarKey, value.name);
    notifyListeners();
  }

  /// Dark theme (the default) or light.
  bool get dark => _dark;

  /// Song tiles (covers, or stand-in tiles) in lists and the player.
  bool get thumbnails => _thumbnails;

  /// Sidebar collapsed to an icon rail.
  bool get rail => _rail;
  PlayerDock get dock => _dock;

  void toggleTheme() {
    _dark = !_dark;
    _write(_themeKey, _dark ? 'dark' : 'light');
    notifyListeners();
  }

  void toggleThumbnails() {
    _thumbnails = !_thumbnails;
    _write(_thumbsKey, _thumbnails ? 'on' : 'off');
    notifyListeners();
  }

  void toggleRail() {
    _rail = !_rail;
    _write(_railKey, _rail ? 'on' : 'off');
    notifyListeners();
  }

  void dockTo(PlayerDock dock) {
    _dock = dock;
    _write(_dockKey, dock.name);
    notifyListeners();
  }
}
