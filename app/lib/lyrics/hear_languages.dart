/// The languages "Hear the words" can be told a song is in (plan 10 I2j):
/// Russian goes to GigaAM, every other one to Whisper with that language
/// code. The codes and English names are Whisper's own (large-v3, which
/// turbo is made from: 99 languages and Cantonese).
library;

/// Russian: heard by GigaAM, not Whisper.
const hearRussian = 'ru';

/// English, the other language at the top of the menu.
const hearEnglish = 'en';

/// Whisper's languages by code, Russian included (it is listed at the top
/// of the menus and heard by GigaAM).
const hearLanguageNames = <String, String>{
  'en': 'English',
  'zh': 'Chinese',
  'de': 'German',
  'es': 'Spanish',
  'ru': 'Russian',
  'ko': 'Korean',
  'fr': 'French',
  'ja': 'Japanese',
  'pt': 'Portuguese',
  'tr': 'Turkish',
  'pl': 'Polish',
  'ca': 'Catalan',
  'nl': 'Dutch',
  'ar': 'Arabic',
  'sv': 'Swedish',
  'it': 'Italian',
  'id': 'Indonesian',
  'hi': 'Hindi',
  'fi': 'Finnish',
  'vi': 'Vietnamese',
  'he': 'Hebrew',
  'uk': 'Ukrainian',
  'el': 'Greek',
  'ms': 'Malay',
  'cs': 'Czech',
  'ro': 'Romanian',
  'da': 'Danish',
  'hu': 'Hungarian',
  'ta': 'Tamil',
  'no': 'Norwegian',
  'th': 'Thai',
  'ur': 'Urdu',
  'hr': 'Croatian',
  'bg': 'Bulgarian',
  'lt': 'Lithuanian',
  'la': 'Latin',
  'mi': 'Maori',
  'ml': 'Malayalam',
  'cy': 'Welsh',
  'sk': 'Slovak',
  'te': 'Telugu',
  'fa': 'Persian',
  'lv': 'Latvian',
  'bn': 'Bengali',
  'sr': 'Serbian',
  'az': 'Azerbaijani',
  'sl': 'Slovenian',
  'kn': 'Kannada',
  'et': 'Estonian',
  'mk': 'Macedonian',
  'br': 'Breton',
  'eu': 'Basque',
  'is': 'Icelandic',
  'hy': 'Armenian',
  'ne': 'Nepali',
  'mn': 'Mongolian',
  'bs': 'Bosnian',
  'kk': 'Kazakh',
  'sq': 'Albanian',
  'sw': 'Swahili',
  'gl': 'Galician',
  'mr': 'Marathi',
  'pa': 'Punjabi',
  'si': 'Sinhala',
  'km': 'Khmer',
  'sn': 'Shona',
  'yo': 'Yoruba',
  'so': 'Somali',
  'af': 'Afrikaans',
  'oc': 'Occitan',
  'ka': 'Georgian',
  'be': 'Belarusian',
  'tg': 'Tajik',
  'sd': 'Sindhi',
  'gu': 'Gujarati',
  'am': 'Amharic',
  'yi': 'Yiddish',
  'lo': 'Lao',
  'uz': 'Uzbek',
  'fo': 'Faroese',
  'ht': 'Haitian Creole',
  'ps': 'Pashto',
  'tk': 'Turkmen',
  'nn': 'Nynorsk',
  'mt': 'Maltese',
  'sa': 'Sanskrit',
  'lb': 'Luxembourgish',
  'my': 'Myanmar',
  'bo': 'Tibetan',
  'tl': 'Tagalog',
  'mg': 'Malagasy',
  'as': 'Assamese',
  'tt': 'Tatar',
  'haw': 'Hawaiian',
  'ln': 'Lingala',
  'ha': 'Hausa',
  'ba': 'Bashkir',
  'jw': 'Javanese',
  'su': 'Sundanese',
  'yue': 'Cantonese',
};

/// The name of [code] for the user ("English"); the code itself for one
/// this build does not know (a row a newer build wrote).
String hearLanguageName(String code) => hearLanguageNames[code] ?? code;

/// The languages after Russian and English, by name: the searchable list.
final List<String> otherHearLanguages = [
  for (final code in hearLanguageNames.keys)
    if (code != hearRussian && code != hearEnglish) code,
]..sort((a, b) => hearLanguageNames[a]!.compareTo(hearLanguageNames[b]!));

/// The languages whose name or code starts a word with [query] (any
/// case): "ukr" finds Ukrainian, "uk" too, "creole" Haitian Creole.
List<String> searchHearLanguages(String query, Iterable<String> codes) {
  final wanted = query.trim().toLowerCase();
  if (wanted.isEmpty) return [...codes];
  return [
    for (final code in codes)
      if (code == wanted ||
          hearLanguageName(code)
              .toLowerCase()
              .split(' ')
              .any((word) => word.startsWith(wanted)))
        code,
  ];
}
