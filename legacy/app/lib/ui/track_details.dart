import 'dart:async';

import 'package:flutter/material.dart';

import '../data/music_metadata.dart';
import '../media/audio_policy.dart';
import '../services/app_controller.dart';

class TrackDetails extends StatefulWidget {
  final AppController controller;
  final Track track;
  const TrackDetails({
    super.key,
    required this.controller,
    required this.track,
  });
  @override
  State<TrackDetails> createState() => _TrackDetailsState();
}

class _TrackDetailsState extends State<TrackDetails> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.enrichTrack(widget.track.id));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller,
          id = widget.track.id,
          meta = c.store.metadata(id),
          lyrics = c.store.lyrics(id),
          asset = c.store.asset(id);
      Widget field(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 175,
              child: Text(label, style: const TextStyle(color: Colors.white60)),
            ),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
      final lines = lyrics['lines'] is List ? lyrics['lines'] as List : [];
      final position = c.current?.id == id
          ? c.player.state.position.inMilliseconds
          : -1;
      var active = -1;
      for (var i = 0; i < lines.length; i++) {
        if ((lines[i]['time_ms'] as int) <= position) active = i;
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.track.title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        widget.track.artist,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh details',
                  onPressed: c.offline || c.enriching(id)
                      ? null
                      : () => c.enrichTrack(id, force: true),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 18),
            field(
              'Imported into Ownsemble',
              displayMusicDate(c.store.importedAt(id)),
            ),
            if (meta['uploadedAt'] is int)
              field(
                'Uploaded to VK',
                displayMusicDate(
                  DateTime.fromMillisecondsSinceEpoch(
                    (meta['uploadedAt'] as int) * 1000,
                  ),
                ),
              ),
            if (meta['album'] is String) field('Album', meta['album']),
            if (meta['subtitle'] is String) field('Version', meta['subtitle']),
            if (meta['artists'] is List)
              field('Artist credits', (meta['artists'] as List).join(', ')),
            if (meta['releaseYear'] is int)
              field('Release year', '${meta['releaseYear']}'),
            if (meta['explicit'] is bool)
              field(
                'Explicit content',
                meta['explicit'] == true ? 'Yes' : 'No',
              ),
            field(
              'Duration',
              '${(asset?.duration ?? widget.track.duration).round()} seconds',
            ),
            if (asset != null)
              field(
                'Saved audio',
                '${(asset.bytes / 1048576).toStringAsFixed(1)} MB · ${asset.entry.split('.').last.toUpperCase()}',
              ),
            const Divider(height: 32),
            Row(
              children: [
                Text('Lyrics', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 12),
                if (c.enriching(id))
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (lyrics['state'] == 'available') ...[
              if (lines.isEmpty)
                SelectableText(
                  lyrics['text'] as String,
                  style: const TextStyle(height: 1.7),
                )
              else
                for (var i = 0; i < lines.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: SelectableText(
                      lines[i]['text'] as String,
                      style: TextStyle(
                        color: i == active
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white70,
                        fontWeight: i == active
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
            ] else
              Text(
                c.enriching(id)
                    ? 'Checking this recording…'
                    : switch (lyrics['state']) {
                        'not_provided' =>
                          'VK does not provide lyrics for this recording.',
                        'failed' => 'Lyrics could not be retrieved. Saved details remain available.',
                        _ =>
                          'Lyrics have not been supplied for this recording.',
                      },
                style: const TextStyle(color: Colors.white60),
              ),
            if (c.metadataErrors[id] != null)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Some VK details could not be refreshed. You can retry.',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
          ],
        ),
      );
    },
  );
}
