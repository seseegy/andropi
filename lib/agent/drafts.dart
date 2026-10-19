import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A file attached to a draft.
typedef DraftFile = ({String path, String name, String? mime});

/// Unsent chat input (text and attachments), kept per chat so it survives leaving the chat or the app being
/// closed. Stored next to the appearance settings (ui.json). Attached files are copied into the app's own storage,
/// because pickers hand out cache files Android may clear.
class Drafts {
  Drafts._();
  static final instance = Drafts._();

  /// The app's files directory; tests point it elsewhere.
  static String root = '/data/data/com.imtaqin.andropi/files';
  static const _max = 50;

  File get _file => File('$root/drafts.json');
  Directory get _filesDir => Directory('$root/draft-files');

  /// chat -> {"text": ..., "files": [{"path", "name", "mime"}]}
  Map<String, Map<String, dynamic>>? _drafts;
  Timer? _saveTimer;

  /// Bumped on every attachment change per chat, so a slow copy can't bring back files removed meanwhile.
  final _generation = <String, int>{};

  Map<String, Map<String, dynamic>> get _all {
    if (_drafts != null) return _drafts!;
    final drafts = <String, Map<String, dynamic>>{};
    try {
      final raw = jsonDecode(_file.readAsStringSync()) as Map;
      raw.forEach((chat, value) {
        // Older drafts were plain strings.
        drafts[chat as String] = value is String ? {'text': value} : (value as Map).cast<String, dynamic>();
      });
    } catch (_) {}
    _drafts = drafts;
    _prune();
    return drafts;
  }

  String get(String? chat) => chat == null ? '' : _all[chat]?['text'] as String? ?? '';

  /// The draft's attachments that still exist.
  List<DraftFile> files(String? chat) {
    if (chat == null) return const [];
    return [
      for (final f in (_all[chat]?['files'] as List? ?? const []).cast<Map>())
        if (File(f['path'] as String).existsSync())
          (path: f['path'] as String, name: f['name'] as String, mime: f['mime'] as String?),
    ];
  }

  /// Saves shortly after typing stops.
  void set(String? chat, String text) {
    if (chat == null) return;
    _update(chat, text: text);
  }

  /// Keeps copies of [files] for the draft; an empty list drops them.
  Future<void> setFiles(String? chat, List<DraftFile> files) async {
    if (chat == null) return;
    final generation = (_generation[chat] ?? 0) + 1;
    _generation[chat] = generation;
    final kept = <Map<String, dynamic>>[];
    for (final f in files) {
      var path = f.path;
      if (!path.startsWith(_filesDir.path)) {
        try {
          _filesDir.createSync(recursive: true);
          final copy = '${_filesDir.path}/${DateTime.now().microsecondsSinceEpoch}_${f.name}';
          await File(path).copy(copy);
          path = copy;
        } catch (_) {
          // Unreadable already: keep the original path; it stays usable for as long as it exists.
        }
      }
      kept.add({'path': path, 'name': f.name, 'mime': f.mime});
    }
    if (_generation[chat] != generation) return;
    _update(chat, files: kept);
  }

  void _update(String chat, {String? text, List<Map<String, dynamic>>? files}) {
    final drafts = _all;
    final entry = Map<String, dynamic>.of(drafts[chat] ?? const {});
    if (text != null) entry['text'] = text;
    if (files != null) entry['files'] = files;
    final empty = (entry['text'] as String? ?? '').trim().isEmpty && (entry['files'] as List? ?? const []).isEmpty;
    if (empty) {
      if (drafts.remove(chat) == null) return;
    } else {
      // Re-insert so the newest drafts sit at the end and the oldest are dropped first.
      drafts
        ..remove(chat)
        ..[chat] = entry;
      while (drafts.length > _max) {
        drafts.remove(drafts.keys.first);
      }
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), flush);
  }

  void flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      _file.writeAsStringSync(jsonEncode(_all));
    } catch (_) {
      // Storage unavailable: drafts stay in memory.
    }
  }

  /// Deletes copies no draft refers to any more. Runs once, when drafts first load (app start), never right after
  /// a send: the message being sent may still be reading them.
  void _prune() {
    final used = {
      for (final d in _drafts!.values)
        for (final f in (d['files'] as List? ?? const []).cast<Map>()) f['path'] as String,
    };
    try {
      if (!_filesDir.existsSync()) return;
      for (final f in _filesDir.listSync().whereType<File>()) {
        if (!used.contains(f.path)) f.deleteSync();
      }
    } catch (_) {}
  }
}
