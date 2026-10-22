import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

/// Uses only the selected, validated local cover; never resolves another source.
Future<void> showArtworkPreview(
  BuildContext context,
  File file, {
  required String title,
  required String artist,
}) => showDialog<void>(
  context: context,
  builder: (context) {
    final screen = MediaQuery.sizeOf(context);
    final edge = min(
      720.0,
      min(screen.width - 96, screen.height - 200),
    ).clamp(120.0, 720.0);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: edge,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close artwork (Escape)',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: edge,
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Center(
                  child: Image.file(
                    file,
                    width: edge,
                    height: edge,
                    cacheWidth: 1440,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Center(
                      child: Text('Artwork is no longer available.'),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  },
);
