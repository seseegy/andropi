import 'dart:convert';
import 'dart:io';

import 'drafts.dart';
import 'models.dart';

/// The agent's plan for a task (the todo_write tool, agent/src/todo.ts): read from the tool call's arguments, since
/// the agent always sends the whole list.
enum TodoStatus { pending, inProgress, completed }

class TodoItem {
  const TodoItem(this.content, this.status, [this.activeForm]);
  final String content;
  final TodoStatus status;

  /// The step as it happens ("Running the tests"), shown while it is in progress.
  final String? activeForm;

  String get label => status == TodoStatus.inProgress ? (activeForm ?? content) : content;

  Map<String, dynamic> toJson() => {
    'content': content,
    'status': switch (status) {
      TodoStatus.pending => 'pending',
      TodoStatus.inProgress => 'in_progress',
      TodoStatus.completed => 'completed',
    },
    'activeForm': ?activeForm,
  };
}

class TodoPlan {
  TodoPlan(this.items);
  final List<TodoItem> items;

  int get done => items.where((t) => t.status == TodoStatus.completed).length;
  int get total => items.length;
  bool get finished => done == total;

  /// The step being worked on, else the next one to do.
  TodoItem? get current =>
      items.where((t) => t.status == TodoStatus.inProgress).firstOrNull ??
      items.where((t) => t.status == TodoStatus.pending).firstOrNull;

  /// 1-based position of [current].
  int get currentNumber {
    final c = current;
    return c == null ? total : items.indexOf(c) + 1;
  }
}

/// The plan to show, and how it relates to the conversation now.
class TodoState {
  TodoState(this.plan, {required this.id, required this.currentTurn});
  final TodoPlan plan;

  /// The todo_write call it came from; dismissing remembers it.
  final String id;

  /// Written since the user's last message: the agent is (or was just) working on it. An older, unfinished plan
  /// may be stale, so the app shows it as paused and lets the user dismiss it.
  final bool currentTurn;
}

/// "None", "null" and the like, which some models send for an empty field.
final _empty = RegExp(r'^(none|null|undefined|n/a)?$', caseSensitive: false);

/// The list a todo_write call carries, cleaned up as the agent does (normalizeTodos in agent/src/todo.ts): an array,
/// or the same array sent as a JSON string.
List<TodoItem> parseTodos(Object? raw) {
  if (raw is String) {
    try {
      return parseTodos(jsonDecode(raw));
    } on FormatException {
      return const [];
    }
  }
  final items = <TodoItem>[];
  if (raw is! List) return items;
  var active = false;
  for (final e in raw) {
    if (e is! Map) continue;
    final content = '${e['content'] ?? e['text'] ?? e['title'] ?? ''}'.trim();
    if (_empty.hasMatch(content)) continue;
    final s = '${e['status'] ?? 'pending'}'.toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    var status = switch (s) {
      'completed' || 'done' || 'complete' => TodoStatus.completed,
      'in_progress' || 'active' || 'doing' => TodoStatus.inProgress,
      _ => TodoStatus.pending,
    };
    // One step at a time.
    if (status == TodoStatus.inProgress) {
      if (active) status = TodoStatus.pending;
      active = true;
    }
    final form = e['activeForm'];
    final activeForm = form is String && !_empty.hasMatch(form.trim()) ? form.trim() : null;
    items.add(TodoItem(content, status, activeForm));
    if (items.length == 50) break;
  }
  return items;
}

/// The plan to show for a chat:
/// - the latest todo_write the agent got through (failed calls are ignored);
/// - from the current turn, always; from an earlier one only while unfinished, for one more user message (the
///   user may be telling it to carry on), and not once dismissed;
/// - [saved] stands in when compaction has dropped the call from the transcript.
TodoState? currentPlan(
  List<ChatEntry> entries, {
  Map<String, ToolRun> tools = const {},
  Set<String> dismissed = const {},
  TodoState? saved,
}) {
  var userMessages = 0;
  for (var i = entries.length - 1; i >= 0; i--) {
    final e = entries[i];
    if (e is UserEntry) userMessages++;
    if (e is! AssistantEntry) continue;
    final blocks = e.orderedBlocks;
    for (var j = blocks.length - 1; j >= 0; j--) {
      final b = blocks[j];
      if (b.kind != BlockKind.toolCall || b.toolName != 'todo_write' || b.args == null) continue;
      if (tools[b.toolCallId]?.status == ToolStatus.failed) continue;
      final items = parseTodos(b.args!['todos']);
      if (items.isEmpty) return null;
      final state = TodoState(TodoPlan(items), id: b.toolCallId ?? '$i:$j', currentTurn: userMessages == 0);
      return _visible(state, userMessages, dismissed);
    }
  }
  // Compacted away: the saved copy, as an earlier turn's plan.
  final compacted = entries.any((e) => e is NoticeEntry && e.text.startsWith('Earlier messages were summarized'));
  if (saved == null || !compacted) return null;
  return _visible(TodoState(saved.plan, id: saved.id, currentTurn: false), 1, dismissed);
}

TodoState? _visible(TodoState s, int userMessagesSince, Set<String> dismissed) {
  if (s.currentTurn) return s;
  if (s.plan.finished || userMessagesSince > 1 || dismissed.contains(s.id)) return null;
  return s;
}

/// The last plan of each chat, kept on disk so it survives compaction dropping its call from the transcript. Next
/// to the drafts (Drafts.root); the 50 most recent chats.
class PlanStore {
  PlanStore._();
  static final instance = PlanStore._();

  File get _file => File('${Drafts.root}/plans.json');
  Map<String, dynamic>? _plans;

  Map<String, dynamic> get _all {
    if (_plans != null) return _plans!;
    try {
      _plans = (jsonDecode(_file.readAsStringSync()) as Map).cast<String, dynamic>();
    } catch (_) {
      _plans = {};
    }
    return _plans!;
  }

  TodoState? recall(String? chat) {
    final saved = chat == null ? null : _all[chat];
    if (saved is! Map) return null;
    final items = parseTodos(saved['todos']);
    return items.isEmpty ? null : TodoState(TodoPlan(items), id: '${saved['id']}', currentTurn: false);
  }

  void remember(String? chat, TodoState state) {
    if (chat == null) return;
    final plans = _all;
    if ((plans[chat] as Map?)?['id'] == state.id &&
        jsonEncode((plans[chat] as Map)['todos']) == jsonEncode([for (final t in state.plan.items) t.toJson()])) {
      return;
    }
    plans
      ..remove(chat)
      ..[chat] = {
        'id': state.id,
        'todos': [for (final t in state.plan.items) t.toJson()],
      };
    while (plans.length > 50) {
      plans.remove(plans.keys.first);
    }
    try {
      _file.writeAsStringSync(jsonEncode(plans));
    } catch (_) {
      // Storage unavailable: the plan just isn't kept past compaction.
    }
  }
}
