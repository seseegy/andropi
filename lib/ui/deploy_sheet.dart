import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:flutter/services.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'accounts_screen.dart';
import 'task_log.dart';
import 'i18n.dart';
import 'theme.dart';

enum DeployTarget { vercel, cloudflare, githubPages, ssh }

extension on DeployTarget {
  String get label => switch (this) {
    DeployTarget.vercel => 'Vercel',
    DeployTarget.cloudflare => 'Cloudflare',
    DeployTarget.githubPages => 'GitHub Pages',
    DeployTarget.ssh => 'SSH server',
  };
  IconData get icon => switch (this) {
    DeployTarget.vercel => SimpleIcons.vercel,
    DeployTarget.cloudflare => SimpleIcons.cloudflare,
    DeployTarget.githubPages => SimpleIcons.github,
    DeployTarget.ssh => LucideIcons.server,
  };
}

/// Where on Cloudflare: Workers (static assets and code) or Pages.
enum CloudflareMode { workers, pages }

/// Deploys the current session's project folder (or a subfolder of it).
Future<void> showDeploySheet(BuildContext context, AgentController agent) async {
  await agent.integrations.refresh();
  await agent.integrations.refreshProjects();
  if (!context.mounted) return;
  final request = await showModalBottomSheet<_DeployRequest>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DeploySheet(agent: agent),
  );
  if (request == null || !context.mounted) return;
  await runWithLog<String?>(
    context,
    title: '${tr('Deploying to')} ${request.label}',
    openUrl: agent.client.openUrl,
    task: (log, ci) => agent.integrations.deploy(
      target: request.target,
      dir: request.dir,
      options: request.options,
      onLine: log,
      onCi: ci,
    ),
    onDone: (context, url) => url == null ? const SizedBox.shrink() : _Result(url: url, openUrl: agent.client.openUrl),
  );
}

class _DeployRequest {
  _DeployRequest(this.target, this.label, this.dir, this.options);

  /// The host's deploy target id (integrations.ts).
  final String target;
  final String label;
  final String dir;
  final Map<String, dynamic> options;
}

class _DeploySheet extends StatefulWidget {
  const _DeploySheet({required this.agent});
  final AgentController agent;

  @override
  State<_DeploySheet> createState() => _DeploySheetState();
}

class _DeploySheetState extends State<_DeploySheet> {
  Integrations get it => widget.agent.integrations;
  late DeployTarget target = it.vercelUser != null
      ? DeployTarget.vercel
      : it.cloudflareConnected
      ? DeployTarget.cloudflare
      : it.github != null
      ? DeployTarget.githubPages
      : DeployTarget.ssh;
  CloudflareMode mode = CloudflareMode.workers;

  final folder = TextEditingController();
  late final name = TextEditingController(text: _base(widget.agent.cwd));
  final message = TextEditingController(text: 'Deploy from AndroPI');
  late final remotePath = TextEditingController(text: it.hosts.firstOrNull?.path ?? '');
  late String? hostId = it.hosts.firstOrNull?.id;
  bool commit = true;
  bool production = true;
  bool buildFirst = false;
  bool spa = false;

  static String _base(String path) => path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'site';

  ProjectInfo? get project => it.projects.where((p) => p.path == widget.agent.cwd).firstOrNull;

  bool get connected => switch (target) {
    DeployTarget.vercel => it.vercelUser != null,
    DeployTarget.cloudflare => it.cloudflareConnected,
    DeployTarget.githubPages => it.github != null,
    DeployTarget.ssh => it.hosts.isNotEmpty,
  };

  @override
  void dispose() {
    for (final c in [folder, name, message, remotePath]) {
      c.dispose();
    }
    super.dispose();
  }

  String get dir {
    final sub = folder.text.trim().replaceAll(RegExp(r'^\./?|/$'), '');
    return sub.isEmpty ? widget.agent.cwd : '${widget.agent.cwd}/$sub';
  }

  String get _targetId => switch (target) {
    DeployTarget.vercel => 'vercel',
    DeployTarget.cloudflare => mode == CloudflareMode.workers ? 'cloudflare_workers' : 'cloudflare_pages',
    DeployTarget.githubPages => 'github_pages',
    DeployTarget.ssh => 'ssh',
  };

  String get _label => target == DeployTarget.cloudflare
      ? (mode == CloudflareMode.workers ? 'Cloudflare Workers' : 'Cloudflare Pages')
      : target.label;

  void _submit() {
    final options = switch (target) {
      DeployTarget.vercel => {'project': name.text.trim(), 'preview': !production},
      DeployTarget.cloudflare => {
        'name': name.text.trim(),
        'root': widget.agent.cwd,
        'build': buildFirst,
        if (mode == CloudflareMode.workers) 'spa': spa else 'preview': !production,
      },
      DeployTarget.githubPages => {'repo': name.text.trim(), 'message': message.text.trim(), 'commit': commit},
      DeployTarget.ssh => {'hostId': hostId, 'remotePath': remotePath.text.trim()},
    };
    Navigator.of(context).pop(_DeployRequest(_targetId, _label, dir, options));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final slug = project?.githubSlug;

    Widget field(TextEditingController c, String label, {String? hint, String? helper}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        autocorrect: false,
        style: const TextStyle(fontFamily: 'GeistMono', fontSize: 14),
        decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper),
      ),
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('Deploy'), style: text.titleLarge),
              const SizedBox(height: 4),
              Text(
                widget.agent.cwd.replaceFirst(RegExp(r'^.*/workspace/?'), 'workspace/'),
                style: TextStyle(fontFamily: mono, fontSize: 12, color: p.muted),
              ),
              const SizedBox(height: 16),
              // Chips wrap onto a second line on narrow screens, where four segments would not fit.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in DeployTarget.values)
                    ChoiceChip(
                      avatar: Icon(t.icon, size: 16),
                      label: Text(t.label),
                      showCheckmark: false,
                      selected: target == t,
                      onSelected: (_) => setState(() => target = t),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (!connected) ...[
                Text(switch (target) {
                  DeployTarget.vercel => 'Connect Vercel to deploy there.',
                  DeployTarget.cloudflare => 'Connect Cloudflare to deploy to Workers or Pages.',
                  DeployTarget.githubPages => 'Connect GitHub to publish with Pages.',
                  DeployTarget.ssh => 'Add a server first.',
                }, style: text.bodySmall),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    await Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => AccountsScreen(agent: widget.agent)));
                    if (mounted) {
                      setState(() {
                        hostId ??= it.hosts.firstOrNull?.id;
                        if (remotePath.text.isEmpty) remotePath.text = it.hosts.firstOrNull?.path ?? '';
                      });
                    }
                  },
                  child: Text(tr('Open accounts & servers')),
                ),
              ] else ...[
                if (target == DeployTarget.cloudflare) ...[
                  SegmentedButton<CloudflareMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: CloudflareMode.workers, label: Text(tr('Workers'))),
                      ButtonSegment(value: CloudflareMode.pages, label: Text(tr('Pages'))),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => setState(() => mode = s.first),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr(
                      mode == CloudflareMode.workers
                          ? 'A static site, or a Worker with a wrangler config (code, assets and bindings).'
                          : 'A static site on pages.dev, with _worker.js or functions if it has them.',
                    ),
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 12),
                ],
                field(folder, 'Folder to deploy', hint: '.  (or dist, build, public…)'),
                ...switch (target) {
                  DeployTarget.vercel => [
                    field(name, 'Project name'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('Production')),
                      subtitle: Text(tr('Off creates a preview deployment')),
                      value: production,
                      onChanged: (v) => setState(() => production = v),
                    ),
                  ],
                  DeployTarget.cloudflare => [
                    field(
                      name,
                      mode == CloudflareMode.workers ? 'Worker name' : 'Project name',
                      helper: mode == CloudflareMode.workers ? 'A wrangler config\'s name wins' : null,
                    ),
                    if (mode == CloudflareMode.workers)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('Single-page app')),
                        subtitle: Text(tr('Unknown paths load index.html (React, Vue, Svelte routers)')),
                        value: spa,
                        onChanged: (v) => setState(() => spa = v),
                      )
                    else
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('Production')),
                        subtitle: Text(tr('Off creates a preview deployment')),
                        value: production,
                        onChanged: (v) => setState(() => production = v),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('Build first')),
                      subtitle: Text(tr('Runs npm run build in the Linux container')),
                      value: buildFirst,
                      onChanged: (v) => setState(() => buildFirst = v),
                    ),
                  ],
                  DeployTarget.githubPages => [
                    if (slug != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('${tr('Publishes')} github.com/$slug', style: text.bodySmall),
                      )
                    else
                      field(name, 'New repository name', helper: 'Created under your account, public'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('Commit changes first')),
                      value: commit,
                      onChanged: (v) => setState(() => commit = v),
                    ),
                    if (commit) field(message, 'Commit message'),
                  ],
                  DeployTarget.ssh => [
                    DropdownButtonFormField<String>(
                      initialValue: hostId,
                      decoration: InputDecoration(labelText: tr('Server')),
                      items: [
                        for (final h in it.hosts)
                          DropdownMenuItem(value: h.id, child: Text('${h.name}  ·  ${h.address}')),
                      ],
                      onChanged: (v) => setState(() {
                        hostId = v;
                        final h = it.hosts.firstWhere((h) => h.id == v);
                        if (h.path != null) remotePath.text = h.path!;
                      }),
                    ),
                    const SizedBox(height: 10),
                    field(remotePath, 'Remote folder', hint: '/var/www/html'),
                  ],
                },
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(LucideIcons.rocket, size: 18),
                  label: Text('${tr('Deploy to')} $_label'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.url, required this.openUrl});
  final String url;
  final Future<void> Function(String) openUrl;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.success.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.globe, size: 18, color: p.success),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              url,
              style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.text),
            ),
          ),
          IconButton(
            tooltip: tr('Copy'),
            icon: const Icon(LucideIcons.copy, size: 16),
            onPressed: () => Clipboard.setData(ClipboardData(text: url)),
          ),
          IconButton(
            tooltip: tr('Open'),
            icon: const Icon(LucideIcons.externalLink, size: 16),
            onPressed: () => openUrl(url),
          ),
        ],
      ),
    );
  }
}
