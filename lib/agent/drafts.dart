import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Unsent chat input, kept per chat so it survives leaving the chat or the app being closed.
/// Stored next to the appearance settings (ui.json).
class Drafts {
  Drafts._();
  static final instance = Drafts._();

  static final _file = File('/data/data/com.imtaqin.andropi/files/drafts.json');
  static const _max = 50;

  Map<String, String>? _drafts;
  Timer? _saveTimer;

  Map<String, String> get _all {
    if (_drafts != null) return _drafts!;
    try {
      _drafts = (jsonDecode(_file.readAsStringSync()) as Map).cast<String, String>();
    } catch (_) {
      _drafts = {};
    }
    return _drafts!;
  }

  String get(String? chat) => chat == null ? '' : _all[chat] ?? '';

  /// Saves shortly after typing stops; an empty text removes the draft.
  void set(String? chat, String text) {
    if (chat == null) return;
    final drafts = _all;
    if (text.trim().isEmpty) {
      if (drafts.remove(chat) == null) return;
    } else {
      // Re-insert so the newest drafts sit at the end and the oldest are dropped first.
      drafts
        ..remove(chat)
        ..[chat] = text;
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
      // Not on a device (tests) or storage unavailable: drafts stay in memory.
    }
  }
}
