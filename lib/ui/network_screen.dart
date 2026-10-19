import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

/// DNS-over-HTTPS and the agent's web search.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  Integrations get it => widget.agent.integrations;
  final customUrl = TextEditingController();
  bool saving = false;

  /// Custom DoH picked but not saved yet: it only takes effect once it has a URL.
  bool pickingCustom = false;

  /// Saves the custom DoH URL, which has to be an https address.
  Future<void> _saveCustom() async {
    final url = customUrl.text.trim();
    if (!RegExp(r'^https://\S+$').hasMatch(url)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Enter an https:// DNS-over-HTTPS address'))));
      return;
    }
    FocusScope.of(context).unfocus();
    await _save({'dns': 'custom', 'dnsUrl': url}, done: tr('DNS updated'));
    if (mounted) setState(() => pickingCustom = false);
  }

  @override
  void initState() {
    super.initState();
    it.refreshSettings().then((s) => customUrl.text = s.dnsUrl ?? '', onError: (_) {});
  }

  @override
  void dispose() {
    customUrl.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, dynamic> patch, {String? done}) async {
    setState(() => saving = true);
    try {
      await it.updateSettings(patch);
      if (done != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) {
        final s = it.settings;
        return Scaffold(
          appBar: AppBar(
            title: Text(tr('Web & DNS')),
            actions: [
              if (saving)
                const Padding(
                  padding: EdgeInsets.only(right: 20),
                  child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
          body: s == null
              ? const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                  children: [
                    const SectionLabel('DNS', padding: EdgeInsets.fromLTRB(4, 8, 4, 10)),
                    Text(
                      tr(
                        'Some networks block sites by answering DNS with a block page. DNS-over-HTTPS sends lookups '
                        'encrypted, so search, model APIs and downloads reach the real servers.',
                      ),
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    SettingsGroup(
                      children: [
                        _DnsOption(
                          icon: SimpleIcons.cloudflare,
                          color: const Color(0xFFF38020),
                          title: tr('Cloudflare'),
                          subtitle: '1.1.1.1 over HTTPS · recommended',
                          selected: s.dns == 'cloudflare',
                          onTap: () {
                            setState(() => pickingCustom = false);
                            _save({'dns': 'cloudflare'});
                          },
                        ),
                        _DnsOption(
                          icon: SimpleIcons.google,
                          color: const Color(0xFF4285F4),
                          title: tr('Google'),
                          subtitle: '8.8.8.8 over HTTPS',
                          selected: s.dns == 'google',
                          onTap: () {
                            setState(() => pickingCustom = false);
                            _save({'dns': 'google'});
                          },
                        ),
                        _DnsOption(
                          icon: LucideIcons.link,
                          color: p.accent,
                          title: tr('Custom DoH'),
                          subtitle: tr('Any JSON DNS-over-HTTPS endpoint'),
                          selected: s.dns == 'custom' || pickingCustom,
                          // Without a URL yet, only open the field; saving an empty one would quietly mean System.
                          onTap: () =>
                              customUrl.text.trim().isEmpty ? setState(() => pickingCustom = true) : _saveCustom(),
                        ),
                        _DnsOption(
                          icon: LucideIcons.smartphone,
                          color: p.muted,
                          title: tr('System'),
                          subtitle: tr('Whatever the phone and network use'),
                          selected: s.dns == 'system',
                          onTap: () {
                            setState(() => pickingCustom = false);
                            _save({'dns': 'system'});
                          },
                        ),
                      ],
                    ),
                    if (s.dns == 'custom' || pickingCustom) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: customUrl,
                        autofocus: pickingCustom,
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        style: const TextStyle(fontFamily: mono, fontSize: 13.5),
                        decoration: InputDecoration(
                          labelText: tr('DoH URL'),
                          hintText: 'https://dns.example/dns-query',
                          suffixIcon: IconButton(
                            tooltip: tr('Save'),
                            icon: const Icon(LucideIcons.check, size: 18),
                            onPressed: saving ? null : _saveCustom,
                          ),
                        ),
                        onSubmitted: (_) => _saveCustom(),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      tr(
                        'Applies to the agent, web search, accounts and deploys. The Linux container uses the same provider.',
                      ),
                      style: text.bodySmall,
                    ),
                    SectionLabel(tr('Web search')),
                    SurfaceCard(
                      child: Row(
                        children: [
                          const IconTile(icon: SimpleIcons.duckduckgo, color: Color(0xFFDE5833)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr('Built in, no key needed'), style: text.titleSmall),
                                const SizedBox(height: 2),
                                Text(
                                  tr(
                                    'The agent has web_search and web_fetch tools (DuckDuckGo, then Brave). '
                                    'Keys below are used first.',
                                  ),
                                  style: text.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr('Optional API keys give faster, more reliable results. Add several to use them in turn:'),
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    _KeyList(
                      service: 's1',
                      icon: LucideIcons.radar,
                      color: const Color(0xFF6366F1),
                      title: 'Search1API',
                      integrations: it,
                      onLink: () => widget.agent.client.openUrl('https://app.s1.dev'),
                      checkCredits: true,
                      footer: SettingsGroup(
                        children: [
                          _FeatureSwitch(
                            icon: LucideIcons.search,
                            title: tr('Search'),
                            subtitle: tr('web_search · 1 credit'),
                            value: s.s1Search,
                            onChanged: (v) => _save({'s1Search': v}),
                          ),
                          _FeatureSwitch(
                            icon: LucideIcons.globe,
                            title: tr('Crawl'),
                            subtitle: tr('web_fetch reads pages, even JavaScript ones · 1 credit'),
                            value: s.s1Crawl,
                            onChanged: (v) => _save({'s1Crawl': v}),
                          ),
                          _FeatureSwitch(
                            icon: LucideIcons.camera,
                            title: tr('Screenshot'),
                            subtitle: tr('web_screenshot lets the agent see a page · 2 credits'),
                            value: s.s1Screenshot,
                            onChanged: (v) => _save({'s1Screenshot': v}),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _KeyList(
                      service: 'brave',
                      icon: SimpleIcons.brave,
                      color: const Color(0xFFFB542B),
                      title: tr('Brave Search API'),
                      integrations: it,
                      onLink: () => widget.agent.client.openUrl('https://brave.com/search/api/'),
                    ),
                    const SizedBox(height: 10),
                    _KeyList(
                      service: 'tavily',
                      icon: LucideIcons.telescope,
                      color: const Color(0xFF0EA5E9),
                      title: tr('Tavily'),
                      integrations: it,
                      onLink: () => widget.agent.client.openUrl('https://app.tavily.com'),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _DnsOption extends StatelessWidget {
  const _DnsOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SettingsRow(
      icon: icon,
      color: color,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? p.accent : null,
          border: selected ? null : Border.all(color: p.border, width: 2),
        ),
        child: selected ? const Icon(LucideIcons.check, size: 13, color: Colors.white) : null,
      ),
    );
  }
}

/// API keys in pasted text: one per line, though spaces, commas and semicolons separate them too. Quotes, blank
/// lines, "#" comments and repeats are dropped. Mirrors parseKeys in agent/src/keyring.ts.
List<String> parseApiKeys(String text) {
  final keys = <String>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.trim().startsWith('#')) continue;
    for (final raw in line.split(RegExp(r'[\s,;]+'))) {
      final key = raw.replaceAll(RegExp(r'''^["'`]+|["'`]+$'''), '');
      if (key.isNotEmpty && !keys.contains(key)) keys.add(key);
    }
  }
  return keys;
}

class _FeatureSwitch extends StatelessWidget {
  const _FeatureSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: icon,
      color: context.palette.accent,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// A search service's keys: the saved ones (masked, each removable) and a box to paste more, one per line.
class _KeyList extends StatefulWidget {
  const _KeyList({
    required this.service,
    required this.icon,
    required this.color,
    required this.title,
    required this.integrations,
    required this.onLink,
    this.checkCredits = false,
    this.footer,
  });
  final String service;
  final IconData icon;
  final Color color;
  final String title;
  final Integrations integrations;
  final VoidCallback onLink;

  /// Offer a credit check per key (Search1API).
  final bool checkCredits;

  /// Shown under the keys once there is at least one.
  final Widget? footer;

  @override
  State<_KeyList> createState() => _KeyListState();
}

class _KeyListState extends State<_KeyList> {
  final input = TextEditingController();
  bool busy = false;
  bool adding = false;
  List<({int? credits, String? error})>? credits;

  @override
  void initState() {
    super.initState();
    input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => busy = true);
    try {
      await job();
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _add() => _run(() async {
    final found = parseApiKeys(input.text);
    if (found.isEmpty) return;
    final added = await widget.integrations.addSearchKeys(widget.service, input.text);
    input.clear();
    credits = null;
    setState(() => adding = false);
    _snack(added == 0 ? tr('These keys are already saved') : tr('{n} keys added').replaceAll('{n}', '$added'));
  });

  /// Removes after a confirmation: the key is only shown masked, so it can't be copied back afterwards.
  Future<void> _remove(int index, String masked) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Remove key {key}?').replaceAll('{key}', masked)),
        content: Text(tr('To use it again you will need to paste it again.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Remove'))),
        ],
      ),
    );
    if (ok == true && mounted) await _removeNow(index, masked);
  }

  Future<void> _removeNow(int index, String masked) => _run(() async {
    await widget.integrations.removeSearchKey(widget.service, index);
    credits = null;
    _snack(tr('Key {key} removed').replaceAll('{key}', masked));
  });

  Future<void> _checkCredits() => _run(() async {
    final out = await widget.integrations.s1Usage();
    if (mounted) setState(() => credits = out);
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final saved = widget.integrations.settings?.keys(widget.service) ?? const <String>[];
    final detected = parseApiKeys(input.text).length;
    final showInput = saved.isEmpty || adding;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconTile(icon: widget.icon, color: widget.color, size: 32),
              const SizedBox(width: 12),
              Expanded(child: Text(widget.title, style: text.titleSmall)),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (saved.isNotEmpty)
                Pill(
                  saved.length == 1 ? tr('1 key') : tr('{n} keys').replaceAll('{n}', '${saved.length}'),
                  color: p.success,
                  dot: true,
                ),
              IconButton(
                tooltip: tr('Get a key'),
                icon: const Icon(LucideIcons.externalLink, size: 16),
                onPressed: widget.onLink,
              ),
            ],
          ),
          if (saved.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (var i = 0; i < saved.length; i++)
              Row(
                children: [
                  Icon(LucideIcons.keyRound, size: 15, color: p.muted),
                  const SizedBox(width: 10),
                  Text(tr('Key {n}').replaceAll('{n}', '${i + 1}'), style: text.bodyMedium),
                  const SizedBox(width: 8),
                  Text(
                    saved[i],
                    style: TextStyle(fontFamily: mono, fontSize: 13, color: p.muted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: credits != null && i < credits!.length
                        ? Text(
                            credits![i].credits != null
                                ? tr('{n} credits').replaceAll('{n}', '${credits![i].credits}')
                                : credits![i].error ?? '',
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(color: credits![i].credits != null ? p.success : p.danger),
                          )
                        : const SizedBox.shrink(),
                  ),
                  IconButton(
                    tooltip: tr('Remove key'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(LucideIcons.trash2, size: 16),
                    onPressed: busy ? null : () => _remove(i, saved[i]),
                  ),
                ],
              ),
            if (!adding)
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: busy ? null : () => setState(() => adding = true),
                    icon: const Icon(LucideIcons.plus, size: 16),
                    label: Text(tr('Add keys')),
                  ),
                  if (widget.checkCredits)
                    TextButton.icon(
                      onPressed: busy ? null : _checkCredits,
                      icon: const Icon(LucideIcons.gauge, size: 16),
                      label: Text(tr('Check credits')),
                    ),
                ],
              ),
          ],
          if (showInput) ...[
            const SizedBox(height: 10),
            TextField(
              controller: input,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.multiline,
              minLines: 1,
              maxLines: 6,
              style: const TextStyle(fontFamily: mono, fontSize: 13),
              decoration: InputDecoration(
                hintText: tr('API keys, one per line'),
                helperText: input.text.trim().isEmpty
                    ? tr('Paste one or more keys')
                    : detected == 1
                    ? tr('1 key detected')
                    : tr('{n} keys detected').replaceAll('{n}', '$detected'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (adding)
                  TextButton(
                    onPressed: () {
                      input.clear();
                      setState(() => adding = false);
                    },
                    child: Text(tr('Cancel')),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy || detected == 0 ? null : _add,
                  child: Text(detected > 1 ? tr('Save {n} keys').replaceAll('{n}', '$detected') : tr('Save')),
                ),
              ],
            ),
          ],
          if (saved.isNotEmpty && widget.footer != null) ...[const SizedBox(height: 10), widget.footer!],
        ],
      ),
    );
  }
}
