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

/// The list a todo_write call carries, cleaned up as the agent does (normalizeTodos in agent/src/todo.ts).
List<TodoItem> parseTodos(Object? raw) {
  final items = <TodoItem>[];
  if (raw is! List) return items;
  var active = false;
  for (final e in raw) {
    if (e is! Map) continue;
    final content = '${e['content'] ?? e['text'] ?? e['title'] ?? ''}'.trim();
    if (content.isEmpty) continue;
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
    final activeForm = e['activeForm'] is String && (e['activeForm'] as String).trim().isNotEmpty
        ? (e['activeForm'] as String).trim()
        : null;
    items.add(TodoItem(content, status, activeForm));
    if (items.length == 50) break;
  }
  return items;
}

/// The plan to show for the chat: the latest one, while it still has steps to do or is from the current turn.
/// A finished plan goes away once the user sends something new.
TodoPlan? currentPlan(List<ChatEntry> entries) {
  var newerUserMessage = false;
  for (var i = entries.length - 1; i >= 0; i--) {
    final e = entries[i];
    if (e is UserEntry) newerUserMessage = true;
    if (e is! AssistantEntry) continue;
    final blocks = e.orderedBlocks;
    for (var j = blocks.length - 1; j >= 0; j--) {
      final b = blocks[j];
      if (b.kind != BlockKind.toolCall || b.toolName != 'todo_write' || b.args == null) continue;
      final items = parseTodos(b.args!['todos']);
      if (items.isEmpty) return null;
      final plan = TodoPlan(items);
      return plan.finished && newerUserMessage ? null : plan;
    }
  }
  return null;
}
