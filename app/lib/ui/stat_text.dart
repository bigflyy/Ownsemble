/// How the song list writes play numbers and dates.
library;

const _monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Heard time: "-" for none, "45 min", "3 h 05 min".
String listenedText(int ms) {
  if (ms <= 0) return '-';
  final minutes = (ms / 60000).round();
  if (minutes < 1) return '<1 min';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
}

/// When a song was last played, from [now]: "Today", "Yesterday", "4 days
/// ago", "3 weeks ago", "8 months ago", "2 years ago"; "Never" for null.
String lastPlayedText(int? ms, DateTime now) {
  if (ms == null) return 'Never';
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  final days = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(at.year, at.month, at.day)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 14) return '$days days ago';
  if (days < 60) return '${(days / 7).round()} weeks ago';
  if (days < 365) return '${(days / 30.4).round()} months ago';
  final years = (days / 365.25).floor();
  return years == 1 ? 'A year ago' : '$years years ago';
}

/// A day as "3 Nov 2026"; "-" for an unknown date (0).
String dayText(int unixSeconds) {
  if (unixSeconds <= 0) return '-';
  final at = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  return '${at.day} ${_monthShort[at.month - 1]} ${at.year}';
}
