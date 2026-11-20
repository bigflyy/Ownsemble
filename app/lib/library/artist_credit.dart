/// One artist VK names on a song (plan 09): its `main_artists` and
/// `featured_artists`, kept per library row in `track_artists`.
///
/// Probe of 2026-11-20 (tool/probe_artists.dart): 71% of a real 2634-song
/// library carries them; when it does, the song's artist text is the main
/// names joined with ", ", plus " feat. " and the featured names.
library;

/// An artist on a song: VK's artist id (a long number, sent as text), the
/// name as this song spells it, the short address name and whether the
/// artist is featured rather than main.
class ArtistCredit {
  const ArtistCredit({
    required this.vkId,
    required this.name,
    this.domain,
    this.featured = false,
  });

  final String vkId;
  final String name;

  /// The artist's address name on VK ("daitetank"); VK's artist page opens
  /// by it as well as by [vkId].
  final String? domain;
  final bool featured;

  @override
  bool operator ==(Object other) =>
      other is ArtistCredit &&
      other.vkId == vkId &&
      other.name == name &&
      other.domain == domain &&
      other.featured == featured;

  @override
  int get hashCode => Object.hash(vkId, name, domain, featured);

  @override
  String toString() =>
      'ArtistCredit($vkId, $name${featured ? ', featured' : ''})';
}

/// The artists of a VK song item: main ones first, then featured ones, each
/// id once (main wins). Entries without an id or a name are skipped.
List<ArtistCredit> vkArtistCredits(Map<String, dynamic> item) {
  final credits = <ArtistCredit>[];
  final seen = <String>{};
  void read(Object? list, {required bool featured}) {
    if (list is! List) return;
    for (final entry in list) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final name = '${entry['name'] ?? ''}'.trim();
      if (id == null || '$id'.isEmpty || name.isEmpty) continue;
      if (!seen.add('$id')) continue;
      final domain = entry['domain'];
      credits.add(
        ArtistCredit(
          vkId: '$id',
          name: name,
          domain: domain is String && domain.isNotEmpty ? domain : null,
          featured: featured,
        ),
      );
    }
  }

  read(item['main_artists'], featured: false);
  read(item['featured_artists'], featured: true);
  return credits;
}

/// Whether two credit lists are the same, in the same order.
bool sameCredits(List<ArtistCredit> a, List<ArtistCredit> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
