import 'package:flutter/material.dart';

import 'collections_controller.dart';
import 'filter_bar.dart' show askViewName;
import 'library_controller.dart';
import 'song_filters.dart';
import 'theme.dart';

/// Width of the full sidebar and of the icon rail.
const sidebarWidth = 236.0;
const railWidth = 68.0;

/// The grouped sidebar (B2): Library, Collections and Listening, with the
/// views planned after the MVP marked "later". Collapses to an icon rail.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.library,
    required this.collections,
    required this.downloads,
    required this.stored,
    this.changed = 0,
    required this.rail,
    required this.canExpand,
    required this.onToggleRail,
  });

  final LibraryController library;
  final CollectionsController? collections;

  /// How many songs are downloaded, for the Downloads count.
  final int downloads;

  /// How many songs have a stored copy, for the On this computer count.
  final int stored;

  /// How many songs VK swapped, for the Changed on VK count.
  final int changed;

  /// Shown as an icon rail.
  final bool rail;

  /// False when the window is too narrow for the full sidebar.
  final bool canExpand;
  final VoidCallback onToggleRail;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final view = library.view;
    final stacks = collections?.stacks ?? const [];
    final filters = library.filters;
    final savedView = view.kind == ViewKind.songs ? filters?.view : null;
    Widget item(
      String label,
      IconData icon,
      LibraryView target, {
      int? count,
      bool later = false,
      bool sub = false,
    }) => _NavItem(
      key: ValueKey(
        'nav-${target.kind.name}${target.stackId == null ? '' : '-${target.stackId}'}',
      ),
      label: label,
      icon: sub ? null : icon,
      count: count,
      later: later,
      selected:
          view == target && (target != LibraryView.songs || savedView == null),
      rail: rail,
      sub: sub,
      onTap: () {
        // Songs from a saved view: all songs again.
        if (target == LibraryView.songs && savedView != null) {
          filters!.showAllSongs();
        }
        library.showView(target);
      },
    );
    return Container(
      width: rail ? railWidth : sidebarWidth,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: rail
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                const _Logo(size: 32),
                if (!rail) ...[
                  const SizedBox(width: 10),
                  const Text(
                    'Ownsemble',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (!rail) const _Section('Library'),
                item(
                  'Songs',
                  Icons.music_note_outlined,
                  LibraryView.songs,
                  count: library.all.length,
                ),
                item(
                  'Artists',
                  Icons.person_outline,
                  const LibraryView(ViewKind.artists),
                  later: true,
                ),
                item(
                  'Downloads',
                  Icons.download_done,
                  const LibraryView(ViewKind.downloads),
                  count: downloads,
                ),
                item(
                  'On this computer',
                  Icons.computer_outlined,
                  const LibraryView(ViewKind.stored),
                  count: stored,
                ),
                item(
                  'Changed on VK',
                  Icons.swap_horiz,
                  const LibraryView(ViewKind.changed),
                  count: changed,
                ),
                if (filters != null && filters.views.isNotEmpty) ...[
                  if (!rail) const _Section('Views'),
                  for (final saved in filters.views)
                    _NavItem(
                      key: ValueKey('nav-view-${saved.id}'),
                      label: saved.name,
                      icon: Icons.bookmark_outline,
                      selected: savedView?.id == saved.id,
                      rail: rail,
                      sub: false,
                      onTap: () {
                        filters.openView(saved.id);
                        library.showView(LibraryView.songs);
                      },
                      onMenu: (position) =>
                          _viewMenu(context, filters, saved, position),
                    ),
                ],
                if (!rail) const _Section('Collections'),
                if (rail)
                  item(
                    'Stacks',
                    Icons.layers_outlined,
                    stacks.isEmpty
                        ? const LibraryView(ViewKind.stack)
                        : LibraryView(ViewKind.stack, stackId: stacks.first.id),
                  )
                else ...[
                  _NavItem(
                    label: 'Stacks',
                    icon: Icons.layers_outlined,
                    selected: false,
                    rail: false,
                    sub: false,
                    onTap: stacks.isEmpty
                        ? null
                        : () => library.showView(
                            LibraryView(
                              ViewKind.stack,
                              stackId: stacks.first.id,
                            ),
                          ),
                    hint: stacks.isEmpty
                        ? 'No Stacks yet: add a song to a new Stack from the '
                              'player or a song\'s right-click menu'
                        : null,
                  ),
                  for (final stack in stacks)
                    item(
                      stack.name,
                      Icons.layers_outlined,
                      LibraryView(ViewKind.stack, stackId: stack.id),
                      count: stack.entryCount,
                      sub: true,
                    ),
                ],
                item(
                  'Playlists',
                  Icons.queue_music,
                  const LibraryView(ViewKind.playlists),
                  later: true,
                ),
                if (!rail) const _Section('Listening'),
                item(
                  'History',
                  Icons.history,
                  const LibraryView(ViewKind.history),
                ),
                item(
                  'Charts',
                  Icons.bar_chart,
                  const LibraryView(ViewKind.charts),
                  later: true,
                ),
              ],
            ),
          ),
          if (canExpand)
            _NavItem(
              key: const ValueKey('toggle-rail'),
              label: rail ? 'Expand sidebar' : 'Collapse sidebar',
              icon: rail
                  ? Icons.keyboard_double_arrow_right
                  : Icons.keyboard_double_arrow_left,
              selected: false,
              rail: rail,
              sub: false,
              onTap: onToggleRail,
            ),
        ],
      ),
    );
  }
}

/// A saved view's right-click menu: Rename or Delete.
Future<void> _viewMenu(
  BuildContext context,
  SongFilters filters,
  SavedView saved,
  Offset position,
) async {
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: const [
      PopupMenuItem(
        key: ValueKey('view-rename'),
        value: 'rename',
        child: Text('Rename...'),
      ),
      PopupMenuItem(
        key: ValueKey('view-delete'),
        value: 'delete',
        child: Text('Delete view'),
      ),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'rename':
      final name = await askViewName(
        context,
        title: 'Rename view',
        initial: saved.name,
        action: 'Rename',
      );
      if (name != null) filters.renameView(saved.id, name);
    case 'delete':
      filters.deleteView(saved.id);
  }
}

/// The app icon "Overlap": three source-colored circles, overlapping.
class _Logo extends StatelessWidget {
  const _Logo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final r = size * 0.3;
    Widget circle(Color color, double dx, double dy) => Positioned(
      left: size / 2 + dx - r,
      top: size / 2 + dy - r,
      child: Container(
        width: r * 2,
        height: r * 2,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.85),
          shape: BoxShape.circle,
        ),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          circle(colors.source1, 0, -size * 0.14),
          circle(colors.source2, -size * 0.15, size * 0.12),
          circle(colors.source3, size * 0.15, size * 0.12),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 16, 10, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.9,
        color: OwnColors.of(context).dim2,
      ),
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.rail,
    required this.sub,
    required this.onTap,
    this.count,
    this.later = false,
    this.hint,
    this.onMenu,
  });

  /// Opens the item's menu at a position on screen (right click).
  final void Function(Offset position)? onMenu;

  final String label;
  final IconData? icon;
  final bool selected;
  final bool rail;
  final bool sub;
  final VoidCallback? onTap;
  final int? count;
  final bool later;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final color = selected ? colors.text : colors.dim;
    final content = rail
        ? Center(
            child: Icon(
              icon,
              size: 20,
              color: selected ? colors.accent : color,
            ),
          )
        : Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: selected ? colors.accent : color),
                const SizedBox(width: 11),
              ] else
                const SizedBox(width: 30),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: sub ? 13 : 14,
                    color: color,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              if (count != null)
                Text(
                  '$count',
                  style: TextStyle(fontSize: 12, color: colors.dim2),
                ),
              if (later)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.line),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'later',
                    style: TextStyle(fontSize: 11, color: colors.dim2),
                  ),
                ),
            ],
          );
    final message = hint ?? (rail ? label : null);
    final item = Material(
      color: selected ? colors.accentBg : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: colors.hover,
        onTap: onTap,
        onSecondaryTapUp: onMenu == null
            ? null
            : (details) => onMenu!(details.globalPosition),
        child: Container(
          height: sub ? 32 : 38,
          padding: EdgeInsets.symmetric(horizontal: rail ? 0 : 10),
          child: content,
        ),
      ),
    );
    return message == null ? item : Tooltip(message: message, child: item);
  }
}
