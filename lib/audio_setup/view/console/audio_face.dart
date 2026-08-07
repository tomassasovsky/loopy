import 'package:flutter/material.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/theme/theme.dart';

/// One captioned group of an Audio tab: its caption, and the blocks under it.
@immutable
class AudioGroup {
  /// Creates an [AudioGroup].
  const AudioGroup({required this.caption, required this.blocks});

  /// The caption over the group. Upper-cased by the caller, as every
  /// [ConsoleGroupLabel] is.
  final String caption;

  /// The cards and banners under the caption, in display order. Separated by
  /// [kConsoleBlockGap] — two blocks of one group sit closer together than two
  /// groups do.
  final List<Widget> blocks;
}

/// The shape all three Audio tabs share: captioned groups that scroll under
/// their own sticky captions.
///
/// Scrolling is not defensive here, it is the common case. An 18-in interface
/// with the device row open is a list of every device the host reports plus
/// three settings rows, and that is taller than the tray sheet — the same
/// problem the per-track routing panel had at eight inputs, so it takes the
/// same answer rather than a second one: each group is its own
/// [SliverMainAxisGroup], so the current caption is pinned overhead and pushed
/// out by the next rather than stacking under it.
///
/// The captions carry [SurfaceTheme.background] rather than the panel tone the
/// routing dialog uses — this face sits directly on the tray sheet, not inside
/// a card.
class AudioFace extends StatelessWidget {
  /// Creates an [AudioFace].
  const AudioFace({required this.groups, this.lastGroupExtent = 0, super.key});

  /// The groups, in display order.
  final List<AudioGroup> groups;

  /// How tall the LAST group is, caption included — 0 when there is only one.
  ///
  /// Stated by the caller rather than measured, because [ConsoleStickyGroups]
  /// needs that height before the group has been laid out, to know when its
  /// real caption has risen far enough to take the bottom preview's place.
  final double lastGroupExtent;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final last = groups.length > 1 ? groups.last : null;
    return Padding(
      // The gap between the tab strip and the first caption. On the group
      // rather than inside the scroll view: a caption that pins flush against
      // the strip is what this space exists to prevent.
      padding: const EdgeInsets.only(top: kConsoleGroupGap),
      child: ConsoleStickyGroups(
        fill: surface.background,
        upcoming: last?.caption,
        upcomingExtent: lastGroupExtent,
        previewKey: const Key('audio_upcoming_group'),
        slivers: [
          for (final (index, group) in groups.indexed) ...[
            if (index > 0)
              const SliverToBoxAdapter(
                child: SizedBox(height: kConsoleGroupGap),
              ),
            SliverMainAxisGroup(
              slivers: [
                ConsolePinnedGroupLabel(
                  group.caption,
                  fill: surface.background,
                ),
                for (final (position, block) in group.blocks.indexed)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: position > 0 ? kConsoleBlockGap : 0,
                      ),
                      child: block,
                    ),
                  ),
              ],
            ),
          ],
          // The sheet's own bottom inset, so the last row can be scrolled clear
          // of the drag handle that rides at the panel's bottom edge.
          const SliverToBoxAdapter(child: SizedBox(height: kConsoleGroupGap)),
        ],
      ),
    );
  }
}
