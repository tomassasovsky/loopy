import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/session/session.dart';
import 'package:session_repository/session_repository.dart';

/// Opens the **Sessions manager**: an alphabetical list of saved sessions with
/// load-on-tap, per-row rename / delete, and a "Save as…" action (an empty
/// state when there are none). Refreshes the catalog first so the list is
/// current, then hands the live [SessionCubit] down through the dialog route
/// (which sits under the root navigator, outside the page's providers).
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
/// the manager's "Save as…" and the top bar's quick Save when no session is
/// open. The dialog's inline check is fast feedback only; [SessionCubit.saveAs]
/// stays the collision authority.
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

/// The Sessions-manager dialog body. Rebuilds off the [SessionCubit]'s
/// `sessions` list so a rename / delete reflows in place.
class _SessionsManagerDialog extends StatelessWidget {
  const _SessionsManagerDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<SessionCubit, SessionState>(
      buildWhen: (a, b) =>
          a.sessions != b.sessions ||
          a.currentSessionName != b.currentSessionName,
      builder: (context, state) {
        return AlertDialog(
          key: const Key('sessions_manager'),
          title: Text(l10n.sessionsManagerTitle),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.sessions.isEmpty)
                  Padding(
                    key: const Key('sessions_empty'),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      l10n.sessionsEmpty,
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final summary in state.sessions)
                          _SessionRow(
                            summary: summary,
                            isCurrent: summary.name == state.currentSessionName,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.close),
            ),
            FilledButton(
              key: const Key('sessions_saveAs'),
              onPressed: () => unawaited(promptSaveAs(context)),
              child: Text(l10n.sessionSaveAs),
            ),
          ],
        );
      },
    );
  }
}

/// A single session row: tap the title to load it, or use the trailing
/// rename / delete actions. The load and delete close the manager (a load
/// swaps the rig, a delete confirms first); a rename keeps it open so the list
/// reflows.
class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.summary, required this.isCurrent});

  final SessionSummary summary;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SessionCubit>();
    return ListTile(
      key: Key('sessions_row_${summary.name}'),
      contentPadding: EdgeInsets.zero,
      // Highlight the open session so the list doubles as a "you are here".
      selected: isCurrent,
      leading: Icon(
        isCurrent ? Icons.folder_open : Icons.folder_outlined,
      ),
      title: Text(summary.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('sessions_rename_${summary.name}'),
            tooltip: l10n.a11ySessionRename(summary.name),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => unawaited(_rename(context, cubit)),
          ),
          IconButton(
            key: Key('sessions_delete_${summary.name}'),
            tooltip: l10n.a11ySessionDelete(summary.name),
            icon: const Icon(Icons.delete_outline),
            onPressed: () => unawaited(_delete(context, cubit)),
          ),
        ],
      ),
      onTap: () {
        unawaited(cubit.loadNamed(summary.name));
        Navigator.of(context).pop();
      },
    );
  }

  Future<void> _rename(BuildContext context, SessionCubit cubit) async {
    final l10n = context.l10n;
    final to = await showSessionNameDialog(
      context: context,
      title: l10n.sessionRenameTitle,
      initial: summary.name,
      // Every other name is taken; the row's own name is allowed (a no-op).
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
    if (context.mounted) Navigator.of(context).pop();
  }
}

/// Shows a name-input dialog (save-as / rename) with an **inline** sanitize +
/// duplicate-slug error, returning the entered name once it clears both checks,
/// or `null` if cancelled. [taken] is the set of slugs already in use (fast
/// feedback only — the cubit/repository remains the collision authority).
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
