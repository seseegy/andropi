import 'package:flutter/material.dart';

import '../agent/agent_client.dart';
import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import '../agent/models.dart';
import 'i18n.dart';
import 'theme.dart';

/// Asks before deleting chats; deleting can't be undone.
Future<bool> confirmDeleteChats(BuildContext context, {required int count, bool includesOpen = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(count == 1 ? tr('Delete this chat?') : '${tr('Delete')} $count ${tr('chats')}?'),
      content: Text(
        [
          tr('The conversation is removed from this phone and cannot be restored. Project files are not touched.'),
          if (includesOpen) tr('The open chat is replaced by a new, empty one.'),
        ].join('\n\n'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: context.palette.danger),
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr('Delete')),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Deletes chats after asking, and says how it went. Returns true when something was deleted.
Future<bool> deleteChats(BuildContext context, AgentController agent, List<SessionSummary> chats) async {
  if (chats.isEmpty) return false;
  final includesOpen = chats.any((s) => s.id == agent.sessionId);
  if (includesOpen && agent.busy) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Stop the agent before deleting the open chat'))));
    return false;
  }
  if (!await confirmDeleteChats(context, count: chats.length, includesOpen: includesOpen)) return false;
  if (!context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final n = await agent.deleteSessions([for (final s in chats) s.path]);
    messenger.showSnackBar(SnackBar(content: Text(n == 1 ? tr('Chat deleted') : '$n ${tr('chats deleted')}')));
    return n > 0;
  } on AgentError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(tr(e.message))));
    return false;
  }
}

/// Deletes a workspace project after showing what would be lost. Returns true when it was deleted.
Future<bool> deleteProjectFlow(BuildContext context, AgentController agent, ProjectInfo project) async {
  final messenger = ScaffoldMessenger.of(context);
  final deleted = await showDialog<int>(
    context: context,
    builder: (_) => _DeleteProjectDialog(agent: agent, project: project),
  );
  if (deleted == null) return false;
  messenger.showSnackBar(
    SnackBar(
      content: Text('${tr('Project deleted')}: ${project.name}${deleted > 0 ? ' (+$deleted ${tr('chats')})' : ''}'),
    ),
  );
  return true;
}

class _DeleteProjectDialog extends StatefulWidget {
  const _DeleteProjectDialog({required this.agent, required this.project});
  final AgentController agent;
  final ProjectInfo project;

  @override
  State<_DeleteProjectDialog> createState() => _DeleteProjectDialogState();
}

class _DeleteProjectDialogState extends State<_DeleteProjectDialog> {
  late final Future<ProjectDeleteCheck> _check = widget.agent.projectDeleteCheck(widget.project.path);
  final _confirm = TextEditingController();
  bool _deleteChats = true;
  bool _deleting = false;
  String? _error;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      final n = await widget.agent.deleteProject(widget.project.path, deleteChats: _deleteChats);
      if (mounted) Navigator.pop(context, n);
    } on AgentError catch (e) {
      if (mounted) {
        setState(() {
          _deleting = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return FutureBuilder<ProjectDeleteCheck>(
      future: _check,
      builder: (context, snap) {
        final check = snap.data;
        final blocked = check != null && check.blockers.isNotEmpty;
        // Work that exists nowhere else needs the name typed out, so it can't go by a slip of the finger.
        final needsName = check?.losesWork ?? false;
        final canDelete =
            check != null && !blocked && !_deleting && (!needsName || _confirm.text.trim() == widget.project.name);
        Widget warning(String s) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('•  $s', style: text.bodyMedium?.copyWith(color: p.danger)),
        );

        return AlertDialog(
          title: Text(tr('Delete project?')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.project.name,
                  style: const TextStyle(fontFamily: mono, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Text(tr('The folder and everything in it is deleted from this phone. This cannot be undone.')),
                if (snap.hasError)
                  warning('${snap.error}')
                else if (check == null)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                else ...[
                  for (final b in check.blockers) warning(tr(b)),
                  if (check.changes > 0) warning('${check.changes} ${tr('uncommitted file(s) will be lost')}'),
                  if (check.unpushed > 0)
                    warning('${check.unpushed} ${tr('commit(s) not pushed anywhere will be lost')}'),
                  if (check.chats > 0 && !blocked)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _deleteChats,
                      onChanged: _deleting ? null : (v) => setState(() => _deleteChats = v ?? true),
                      title: Text('${tr('Also delete')} ${check.chats} ${tr('chat(s) in this project')}'),
                    ),
                  if (needsName && !blocked) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      enabled: !_deleting,
                      autocorrect: false,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: tr('Type the project name to confirm'),
                        hintText: widget.project.name,
                        isDense: true,
                      ),
                    ),
                  ],
                ],
                if (_error != null) warning(tr(_error!)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _deleting ? null : () => Navigator.pop(context),
              child: Text(blocked ? tr('Close') : tr('Cancel')),
            ),
            if (!blocked)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: p.danger),
                onPressed: canDelete ? _delete : null,
                child: _deleting
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(tr('Delete project')),
              ),
          ],
        );
      },
    );
  }
}
