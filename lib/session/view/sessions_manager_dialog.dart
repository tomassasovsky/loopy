import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/session/session.dart';
import 'package:session_repository/session_repository.dart';

/// Opens the **Sessions** popup — the single place to handle sessions (like
/// Loopy Pro's projects browser): the current session with Save / Save As, a
/// grid of saved-session cards (load-on-tap; per-card rename / duplicate /
/// delete), and the mixdown / stems exports. Refreshes the catalog first, then
/// hands the live [SessionCubit] down through the dialog route (which sits
/// under the root navigator, outside the page's providers).
Future<void> showSessionsManager(BuildContext context) async {
  final cubit = context.read<SessionCubit>();
  await cubit.refreshSessions();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => BlocProvider<SessionCubit>.value(
      value: cubit,
      child: const _SessionsManagerDialog(),
    ),
  );
}

/// Prompts for a name and saves the live rig as a NEW named session. Shared by
/// the popup's "Save as…" and the top bar's quick Save when no session is open.
/// The dialog's inline check is fast feedback only; [SessionCubit.saveAs] stays
/// the collision authority.
Future<void> promptSaveAs(BuildContext context) async {
  final cubit = context.read<SessionCubit>();
  final l10n = context.l10n;
  final name = await showSessionNameDialog(
    context: context,
    title: l10n.sessionNewTitle,
    taken: cubit.state.sessions.map((s) => s.name).toSet(),
  );
  if (name == null) return;
  await cubit.saveAs(name);
}

/// Prompts for a name and duplicates saved session [from] to a new copy.
Future<void> promptDuplicate(BuildContext context, String from) async {
  final cubit = context.read<SessionCubit>();
  final l10n = context.l10n;
  final to = await showSessionNameDialog(
    context: context,
    title: l10n.sessionDuplicateTitle,
    initial: from,
    taken: cubit.state.sessions.map((s) => s.name).toSet(),
  );
  if (to == null) return;
  await cubit.duplicateSession(from, to);
}

/// The Sessions popup: a fixed-size panel with a header (current session +
/// Save / Save As), a grid of session cards, and the exports bar. Rebuilds off
/// the cubit's `sessions` + `currentSessionName`.
class _SessionsManagerDialog extends StatelessWidget {
  const _SessionsManagerDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Dialog(
      key: const Key('sessions_manager'),
      child: SizedBox(
        width: 620,
        height: 520,
        child: BlocBuilder<SessionCubit, SessionState>(
          buildWhen: (a, b) =>
              a.sessions != b.sessions ||
              a.currentSessionName != b.currentSessionName,
          builder: (context, state) {
            final cubit = context.read<SessionCubit>();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(state: state),
                const Divider(height: 1),
                Expanded(
                  child: state.sessions.isEmpty
                      ? Center(
                          child: Padding(
                            key: const Key('sessions_empty'),
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l10n.sessionsEmpty,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 190,
                                mainAxisExtent: 96,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                          itemCount: state.sessions.length,
                          itemBuilder: (context, i) {
                            final summary = state.sessions[i];
                            return _SessionCard(
                              summary: summary,
                              isCurrent:
                                  summary.name == state.currentSessionName,
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
                _ExportsBar(cubit: cubit),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The popup header: the title + current session name (or "Unsaved"), the Save
/// (write-back) and Save As actions, and a close affordance.
class _Header extends StatelessWidget {
  const _Header({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SessionCubit>();
    final theme = Theme.of(context);
    final current = state.currentSessionName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.sessionsManagerTitle,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  current ?? l10n.sessionUnsaved,
                  key: const Key('sessions_currentName'),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: current == null
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            key: const Key('sessions_save'),
            // Write back to the open session, or prompt Save-As when none.
            onPressed: () => current == null
                ? unawaited(promptSaveAs(context))
                : unawaited(cubit.save()),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(l10n.sessionSave),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const Key('sessions_saveAs'),
            onPressed: () => unawaited(promptSaveAs(context)),
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.sessionSaveAs),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const Key('sessions_close'),
            tooltip: l10n.close,
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// A single saved-session **card**: tap to load (closes the popup), with a
/// per-card menu for rename / duplicate / delete. The open session is
/// highlighted.
class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.summary, required this.isCurrent});

  final SessionSummary summary;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SessionCubit>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: Key('sessions_card_${summary.name}'),
      color: isCurrent
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          unawaited(cubit.loadNamed(summary.name));
          Navigator.of(context).pop();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isCurrent ? Icons.folder_open : Icons.folder_outlined,
                    size: 18,
                    color: isCurrent
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const Spacer(),
                  _CardMenu(summary: summary),
                ],
              ),
              const Spacer(),
              Text(
                summary.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isCurrent
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A session card's overflow menu: rename / duplicate / delete.
class _CardMenu extends StatelessWidget {
  const _CardMenu({required this.summary});

  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<String>(
      key: Key('sessions_menu_${summary.name}'),
      tooltip: l10n.a11ySessionMenu,
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        final cubit = context.read<SessionCubit>();
        switch (value) {
          case 'rename':
            unawaited(_rename(context, cubit));
          case 'duplicate':
            unawaited(promptDuplicate(context, summary.name));
          case 'delete':
            unawaited(_delete(context, cubit));
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          key: Key('sessions_rename_${summary.name}'),
          value: 'rename',
          child: Text(l10n.sessionRename),
        ),
        PopupMenuItem(
          key: Key('sessions_duplicate_${summary.name}'),
          value: 'duplicate',
          child: Text(l10n.sessionDuplicate),
        ),
        PopupMenuItem(
          key: Key('sessions_delete_${summary.name}'),
          value: 'delete',
          child: Text(l10n.sessionDelete),
        ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, SessionCubit cubit) async {
    final l10n = context.l10n;
    final to = await showSessionNameDialog(
      context: context,
      title: l10n.sessionRenameTitle,
      initial: summary.name,
      // Every other name is taken; the card's own name is allowed (a no-op).
      taken: cubit.state.sessions
          .map((s) => s.name)
          .where((n) => n != summary.name)
          .toSet(),
    );
    if (to == null) return;
    await cubit.renameSession(summary.name, to);
  }

  Future<void> _delete(BuildContext context, SessionCubit cubit) async {
    final confirmed = await _confirmDelete(context, summary.name);
    if (!confirmed) return;
    await cubit.deleteSession(summary.name);
  }
}

/// The popup's export bar: a mixdown WAV and per-track stems.
class _ExportsBar extends StatelessWidget {
  const _ExportsBar({required this.cubit});

  final SessionCubit cubit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          TextButton.icon(
            key: const Key('sessions_exportMixdown'),
            onPressed: () => unawaited(cubit.exportMixdown()),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(l10n.exportMixdown),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: const Key('sessions_exportStems'),
            onPressed: () => unawaited(cubit.exportStems()),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(l10n.exportStems),
          ),
        ],
      ),
    );
  }
}

/// Shows a name-input dialog (save-as / rename / duplicate) with an **inline**
/// sanitize + duplicate-slug error, returning the entered name once it clears
/// both checks, or `null` if cancelled. [taken] is the set of slugs already in
/// use (fast feedback only — the cubit/repository remains the collision
/// authority).
Future<String?> showSessionNameDialog({
  required BuildContext context,
  required String title,
  required Set<String> taken,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SessionNameDialog(
      title: title,
      initial: initial,
      taken: taken,
    ),
  );
}

class _SessionNameDialog extends StatefulWidget {
  const _SessionNameDialog({
    required this.title,
    required this.initial,
    required this.taken,
  });

  final String title;
  final String initial;
  final Set<String> taken;

  @override
  State<_SessionNameDialog> createState() => _SessionNameDialogState();
}

class _SessionNameDialogState extends State<_SessionNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final raw = _controller.text;
    final slug = sessionSlug(raw);
    if (slug == null) {
      setState(() => _error = l10n.sessionNameInvalid);
      return;
    }
    if (widget.taken.contains(slug)) {
      setState(() => _error = l10n.sessionNameDuplicate(slug));
      return;
    }
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('sessionName_field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: l10n.sessionNameHint,
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const Key('sessionName_save'),
          onPressed: _submit,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// Confirms a destructive delete of session [name]; resolves `true` only if the
/// user confirms.
Future<bool> _confirmDelete(BuildContext context, String name) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sessionDeleteConfirmTitle(name)),
      content: Text(l10n.sessionDeleteConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const Key('sessionDelete_confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.sessionDelete),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
