import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/updater.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

bool _sheetOpen = false;

/// The update sheet: what's new, download progress, install. Only one is open at a time.
Future<void> showUpdateSheet(BuildContext context, AgentController agent, {bool check = false}) async {
  final updater = Updater.instance;
  if (check && updater.phase != UpdatePhase.downloading && updater.phase != UpdatePhase.ready) {
    updater.check(manual: true);
  }
  if (_sheetOpen) return;
  _sheetOpen = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _UpdateSheet(agent: agent),
    );
  } finally {
    _sheetOpen = false;
  }
}

/// Installs the downloaded update, warning first when the agent is mid-run (installing restarts the app).
Future<void> installUpdate(BuildContext context, AgentController agent) async {
  final messenger = ScaffoldMessenger.of(context);
  if (agent.busy) {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('pi is still working')),
        content: Text(tr('Installing the update closes AndroPI and stops the current run.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Wait'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Install anyway'))),
        ],
      ),
    );
    if (go != true) return;
  }
  final problem = await Updater.instance.install();
  if (problem != null) {
    messenger.showSnackBar(SnackBar(content: Text(tr(problem))));
  } else if (Updater.instance.awaitingPermission) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Allow AndroPI to install apps, then come back. The install continues on its own.'))),
    );
  }
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.agent});
  final AgentController agent;

  Updater get updater => Updater.instance;

  Future<void> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Cancel the download?')),
        content: Text(tr('What was downloaded so far is deleted. You can start again any time.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Keep downloading'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Cancel download'))),
        ],
      ),
    );
    if (ok == true) await updater.cancelDownload();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final release = updater.latest;
        final d = updater.download;
        final (title, subtitle) = switch (updater.phase) {
          UpdatePhase.checking => (tr('Checking for updates…'), null),
          UpdatePhase.available => ('${tr('Update available')}: ${release!.version}', _sizeLine(release)),
          UpdatePhase.downloading => ('${tr('Downloading')} ${d.version ?? ''}', null),
          UpdatePhase.ready => (tr('Update ready to install'), d.version),
          UpdatePhase.failed => (tr('Download failed'), null),
          UpdatePhase.upToDate => (tr('AndroPI is up to date'), null),
          UpdatePhase.idle => (tr('App updates'), null),
        };
        final notes = release?.notes ?? '';
        final showNotes =
            notes.isNotEmpty &&
            (updater.phase == UpdatePhase.available ||
                (updater.phase != UpdatePhase.upToDate && d.version == release?.version));

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconTile(
                    icon: switch (updater.phase) {
                      UpdatePhase.failed => LucideIcons.triangleAlert,
                      UpdatePhase.upToDate => LucideIcons.circleCheck,
                      UpdatePhase.ready => LucideIcons.packageCheck,
                      _ => LucideIcons.download,
                    },
                    color: updater.phase == UpdatePhase.failed ? p.danger : p.accent,
                    size: 40,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: text.titleMedium),
                        Text(
                          ['${tr('Installed')}: ${updater.currentVersion}', ?subtitle].join('  ·  '),
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (updater.phase == UpdatePhase.downloading) ...[
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: d.status == 'running' ? d.progress : null, minHeight: 6),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr(d.reasonText ?? (d.status == 'pending' ? 'Starting…' : 'Downloading')),
                        style: text.bodySmall,
                      ),
                    ),
                    Text(
                      d.total > 0
                          ? '${formatBytes(d.downloaded)} / ${formatBytes(d.total)}  ·  ${(d.progress! * 100).round()}%'
                          : formatBytes(d.downloaded),
                      style: text.bodySmall?.copyWith(fontFamily: mono),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  tr('You can leave AndroPI; the download continues in the background.'),
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
              ],
              if (updater.error != null) ...[
                const SizedBox(height: 14),
                Text(tr(updater.error!), style: text.bodySmall?.copyWith(color: p.danger)),
              ],
              if (showNotes) ...[
                const SizedBox(height: 16),
                Text(tr("What's new"), style: text.labelSmall),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.35),
                  child: Container(
                    decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.all(12),
                    child: SingleChildScrollView(
                      child: MarkdownBody(
                        data: notes,
                        onTapLink: (_, href, _) {
                          if (href != null) agent.client.openUrl(href);
                        },
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              ..._actions(context),
              if (updater.phase == UpdatePhase.upToDate ||
                  updater.phase == UpdatePhase.idle ||
                  updater.phase == UpdatePhase.available) ...[
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: updater.autoCheck,
                  onChanged: updater.setAutoCheck,
                  title: Text(tr('Check for updates automatically'), style: text.bodyMedium),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _sizeLine(AppRelease r) => r.size > 0 ? formatBytes(r.size) : r.assetName;

  List<Widget> _actions(BuildContext context) {
    final release = updater.latest;
    switch (updater.phase) {
      case UpdatePhase.checking:
        return [const Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)))];
      case UpdatePhase.available:
        return [
          PrimaryButton(label: tr('Update now'), icon: LucideIcons.download, onPressed: updater.startDownload),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () async {
                    await updater.skip(release!.version);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(tr('Skip this version')),
                ),
              ),
              Expanded(
                child: TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Later'))),
              ),
            ],
          ),
        ];
      case UpdatePhase.downloading:
        return [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(onPressed: () => _confirmCancel(context), child: Text(tr('Cancel download'))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Hide'))),
              ),
            ],
          ),
        ];
      case UpdatePhase.ready:
        return [
          PrimaryButton(
            label: tr('Install now'),
            icon: LucideIcons.packageCheck,
            onPressed: () => installUpdate(context, agent),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton(onPressed: updater.cancelDownload, child: Text(tr('Discard'))),
              ),
              Expanded(
                child: TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Later'))),
              ),
            ],
          ),
        ];
      case UpdatePhase.failed:
        return [
          PrimaryButton(
            label: tr('Try again'),
            icon: LucideIcons.refreshCw,
            onPressed: () async {
              // After a restart the release is not known yet; look it up first.
              if (updater.latest == null) await updater.check(manual: true);
              if (updater.latest != null) await updater.startDownload();
            },
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: updater.cancelDownload, child: Text(tr('Dismiss'))),
        ];
      case UpdatePhase.upToDate:
      case UpdatePhase.idle:
        return [
          OutlinedButton.icon(
            onPressed: () => updater.check(manual: true),
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: Text(tr('Check again')),
          ),
        ];
    }
  }
}
