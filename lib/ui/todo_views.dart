import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/models.dart';
import '../agent/todos.dart';
import 'i18n.dart';
import 'theme.dart';

/// The steps of a plan, each with its state: ✓ done, ◐ in progress, ○ to do.
class TodoChecklist extends StatelessWidget {
  const TodoChecklist({super.key, required this.items});
  final List<TodoItem> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: switch (t.status) {
                    TodoStatus.completed => Icon(LucideIcons.circleCheck, size: 17, color: p.success),
                    TodoStatus.inProgress => Icon(LucideIcons.circleDot, size: 17, color: p.accent),
                    TodoStatus.pending => Icon(LucideIcons.circle, size: 17, color: p.faint),
                  },
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.label,
                    style: text.bodyMedium?.copyWith(
                      color: switch (t.status) {
                        TodoStatus.completed => p.muted,
                        TodoStatus.inProgress => p.text,
                        TodoStatus.pending => p.text,
                      },
                      fontWeight: t.status == TodoStatus.inProgress ? FontWeight.w600 : null,
                      decoration: t.status == TodoStatus.completed ? TextDecoration.lineThrough : null,
                      decorationColor: p.faint,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Steps · 3/7" with a progress bar. ("Plan" is taken by plan mode.)
class _PlanHeader extends StatelessWidget {
  const _PlanHeader({required this.plan});
  final TodoPlan plan;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(LucideIcons.listTodo, size: 15, color: p.accent),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('Steps'), style: text.titleSmall)),
            Text(
              '${plan.done}/${plan.total}',
              style: text.labelMedium?.copyWith(color: plan.finished ? p.success : p.muted),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: plan.total == 0 ? 0 : plan.done / plan.total,
            minHeight: 4,
            color: plan.finished ? p.success : p.accent,
            backgroundColor: p.border,
          ),
        ),
      ],
    );
  }
}

/// A todo_write call in the chat: the plan as it stood at that point.
class TodoCard extends StatelessWidget {
  const TodoCard({super.key, required this.block});
  final Block block;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final items = parseTodos(block.args?['todos']);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: items.isEmpty
          ? Row(
              children: [
                SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: p.muted)),
                const SizedBox(width: 10),
                Text(
                  block.args == null ? tr('Planning…') : tr('Plan cleared'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PlanHeader(plan: TodoPlan(items)),
                const SizedBox(height: 8),
                TodoChecklist(items: items),
              ],
            ),
    );
  }
}

/// Above the input while there is a plan: the current step and progress; tap for the whole list.
class TodoProgressBar extends StatelessWidget {
  const TodoProgressBar({super.key, required this.plan});
  final TodoPlan plan;

  void _open(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            children: [
              _PlanHeader(plan: plan),
              const SizedBox(height: 12),
              TodoChecklist(items: plan.items),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final current = plan.current;
    final label = plan.finished
        ? tr('All {n} steps done').replaceAll('{n}', '${plan.total}')
        : '${plan.currentNumber}/${plan.total} · ${current?.label ?? ''}';
    return Semantics(
      button: true,
      label: '${tr('Steps')}: $label',
      excludeSemantics: true,
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      plan.finished ? LucideIcons.circleCheck : LucideIcons.listTodo,
                      size: 15,
                      color: plan.finished ? p.success : p.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: p.text, fontWeight: FontWeight.w500),
                      ),
                    ),
                    Icon(LucideIcons.chevronUp, size: 16, color: p.muted),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: plan.total == 0 ? 0 : plan.done / plan.total,
                    minHeight: 3,
                    color: plan.finished ? p.success : p.accent,
                    backgroundColor: p.border,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
