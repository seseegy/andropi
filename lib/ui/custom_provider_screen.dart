import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_client.dart';
import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

const _apis = {
  'openai-completions': 'OpenAI compatible (Chat Completions)',
  'openai-responses': 'OpenAI Responses',
  'anthropic-messages': 'Anthropic Messages',
  'google-generative-ai': 'Google Gemini',
};

const _urlHints = {
  'openai-completions': 'https://api.example.com/v1',
  'openai-responses': 'https://api.openai.com/v1',
  'anthropic-messages': 'https://api.anthropic.com',
  'google-generative-ai': 'https://generativelanguage.googleapis.com/v1beta',
};

/// Adds or edits an endpoint reached with a base URL and an API key (agent/src/providers.ts).
class CustomProviderScreen extends StatefulWidget {
  const CustomProviderScreen({super.key, required this.agent, this.existing});
  final AgentController agent;
  final CustomProvider? existing;

  @override
  State<CustomProviderScreen> createState() => _CustomProviderScreenState();
}

class _CustomProviderScreenState extends State<CustomProviderScreen> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _id = TextEditingController(text: widget.existing?.id);
  late final _baseUrl = TextEditingController(text: widget.existing?.baseUrl);
  final _apiKey = TextEditingController();
  final _newModel = TextEditingController();
  late String _api = widget.existing?.api ?? 'openai-completions';
  late bool _idTouched = widget.existing != null;
  bool _showKey = false;
  bool _fetching = false;
  bool _saving = false;
  String? _problem;
  String _query = '';

  /// Every model seen (saved, fetched or typed in); only [_selected] ones are saved.
  final _models = <String, CustomModel>{};
  final _selected = <String>{};

  CustomProvider? get existing => widget.existing;

  @override
  void initState() {
    super.initState();
    for (final m in existing?.models ?? const <CustomModel>[]) {
      _models[m.id] = m;
      _selected.add(m.id);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _id, _baseUrl, _apiKey, _newModel]) {
      c.dispose();
    }
    super.dispose();
  }

  String _slug(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  Future<void> _fetch() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _fetching = true;
      _problem = null;
    });
    try {
      final key = _apiKey.text.trim();
      final found = await widget.agent.fetchProviderModels(
        api: _api,
        baseUrl: _baseUrl.text.trim(),
        apiKey: key,
        providerId: key.isEmpty ? existing?.id : null,
      );
      if (!mounted) return;
      setState(() {
        final selectAll = _selected.isEmpty;
        for (final m in found) {
          _models[m.id] = m;
          if (selectAll) _selected.add(m.id);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Models found')}: ${found.length}')));
    } on AgentError catch (e) {
      if (mounted) setState(() => _problem = 'Could not fetch models: ${e.message}');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  void _addModel() {
    final id = _newModel.text.trim();
    if (id.isEmpty) return;
    setState(() {
      _models.putIfAbsent(id, () => CustomModel({'id': id}));
      _selected.add(id);
      _newModel.clear();
    });
  }

  Future<void> _save() async {
    final id = _id.text.trim();
    String? problem;
    if (_name.text.trim().isEmpty) {
      problem = 'Enter a name.';
    } else if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(id)) {
      problem = 'Provider ID: lowercase letters, digits, - and _ only.';
    } else if (!(Uri.tryParse(_baseUrl.text.trim())?.hasScheme ?? false)) {
      problem = 'Enter a full base URL (https://…).';
    } else if (_selected.isEmpty) {
      problem = 'Pick at least one model, or fetch them from the endpoint.';
    }
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      await widget.agent.saveCustomProvider({
        'previousId': ?existing?.id,
        'id': id,
        'name': _name.text.trim(),
        'api': _api,
        'baseUrl': _baseUrl.text.trim(),
        'apiKey': _apiKey.text.trim(),
        'models': [
          for (final m in _models.values)
            if (_selected.contains(m.id)) m.json,
        ],
      });
      if (mounted) Navigator.of(context).pop(true);
    } on AgentError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${tr('Remove')} ${existing!.name}?'),
        content: Text(tr('Its API key and model list are deleted from this device.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Remove'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.agent.deleteCustomProvider(existing!.id);
      if (mounted) Navigator.of(context).pop(true);
    } on AgentError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    }
  }

  static String _tokens(int n) =>
      n >= 1000000 ? '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M' : '${(n / 1000).round()}k';

  String _details(CustomModel m) => [
    if (m.name != null) m.id,
    if (m.contextWindow != null) '${_tokens(m.contextWindow!)} ${tr('context')}',
    if (m.maxTokens != null) '${_tokens(m.maxTokens!)} ${tr('output')}',
  ].join('  ·  ');

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final q = _query.toLowerCase();
    final visible = _models.values
        .where((m) => q.isEmpty || m.id.toLowerCase().contains(q) || (m.name?.toLowerCase().contains(q) ?? false))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Custom provider' : existing!.name),
        actions: [
          if (existing != null)
            IconButton(
              tooltip: tr('Remove'),
              onPressed: _saving ? null : _delete,
              icon: Icon(LucideIcons.trash2, size: 18, color: p.danger),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: p.border),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: tr('Name'), hintText: tr('My proxy')),
            onChanged: (v) {
              if (!_idTouched) _id.text = _slug(v);
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _id,
            autocorrect: false,
            style: const TextStyle(fontFamily: mono, fontSize: 13),
            decoration: InputDecoration(labelText: tr('Provider ID'), hintText: 'my-proxy'),
            onChanged: (_) => _idTouched = true,
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _api,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('API type')),
            items: [for (final e in _apis.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _api = v ?? _api),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _baseUrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontFamily: mono, fontSize: 13),
            decoration: InputDecoration(labelText: tr('Base URL'), hintText: _urlHints[_api]),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _apiKey,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: !_showKey,
            style: const TextStyle(fontFamily: mono, fontSize: 13),
            decoration: InputDecoration(
              labelText: tr('API key'),
              hintText: existing?.hasKey == true ? 'Saved. Leave empty to keep it' : 'Optional for local servers',
              suffixIcon: IconButton(
                onPressed: () => setState(() => _showKey = !_showKey),
                icon: Icon(_showKey ? LucideIcons.eyeOff : LucideIcons.eye, size: 18),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(tr('The key is stored encrypted on this device.'), style: text.bodySmall?.copyWith(color: p.muted)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _fetching ? null : _fetch,
            icon: _fetching
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.refreshCw, size: 16),
            label: Text(_fetching ? 'Fetching models…' : 'Fetch available models'),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('${tr('Models')} (${_selected.length} ${tr('selected')})', style: text.titleSmall)),
              if (_models.isNotEmpty) ...[
                TextButton(
                  onPressed: () => setState(() => _selected.addAll(visible.map((m) => m.id))),
                  child: Text(tr('All')),
                ),
                TextButton(
                  onPressed: () => setState(() => _selected.removeAll(visible.map((m) => m.id))),
                  child: Text(tr('None')),
                ),
              ],
            ],
          ),
          if (_models.length > 8) ...[
            const SizedBox(height: 6),
            TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: tr('Search models'),
                isDense: true,
                prefixIcon: Icon(LucideIcons.search, size: 18),
              ),
            ),
          ],
          if (_models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                tr('Fetch the list from the endpoint, or type a model ID below.'),
                style: text.bodySmall?.copyWith(color: p.muted),
              ),
            ),
          for (final m in visible)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _selected.contains(m.id),
              onChanged: (v) => setState(() => v == true ? _selected.add(m.id) : _selected.remove(m.id)),
              title: Text(
                m.name ?? m.id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: mono, fontSize: 13),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_details(m).isNotEmpty) Text(_details(m)),
                  const SizedBox(height: 4),
                  // What the model can do; tap to correct it when the endpoint doesn't say.
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _CapabilityChip(
                        icon: LucideIcons.brain,
                        label: m.reasoning && !m.canDisableThinking ? tr('Reasoning (always on)') : tr('Reasoning'),
                        on: m.reasoning,
                        onTap: () => setState(() => _models[m.id] = m.copyWith(reasoning: !m.reasoning)),
                      ),
                      _CapabilityChip(
                        icon: LucideIcons.eye,
                        label: tr('Vision'),
                        on: m.vision,
                        onTap: () => setState(() => _models[m.id] = m.copyWith(vision: !m.vision)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newModel,
                  autocorrect: false,
                  style: const TextStyle(fontFamily: mono, fontSize: 13),
                  decoration: InputDecoration(hintText: tr('Add model ID manually'), isDense: true),
                  onSubmitted: (_) => _addModel(),
                ),
              ),
              IconButton(onPressed: _addModel, icon: const Icon(LucideIcons.plus, size: 18)),
            ],
          ),
          if (_problem != null) ...[
            const SizedBox(height: 12),
            Text(_problem!, style: text.bodySmall?.copyWith(color: p.danger)),
          ],
          const SizedBox(height: 20),
          PrimaryButton(label: tr('Save'), icon: LucideIcons.check, busy: _saving, onPressed: _save),
        ],
      ),
    );
  }
}

/// A capability a model has (filled) or not (outlined); tapping switches it.
class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.icon, required this.label, required this.on, required this.onTap});
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = on ? p.accent : p.faint;
    return Semantics(
      button: true,
      toggled: on,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: on ? p.accent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? Colors.transparent : p.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 11.5, color: on ? p.accent : p.muted)),
            ],
          ),
        ),
      ),
    );
  }
}
