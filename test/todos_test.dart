import 'package:andropi/agent/models.dart';
import 'package:andropi/agent/todos.dart';
import 'package:andropi/ui/theme.dart';
import 'package:andropi/ui/todo_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AssistantEntry plan(List<Map<String, dynamic>> todos) => AssistantEntry()
  ..applyMessage({
    'content': [
      {'type': 'text', 'text': 'On it.'},
      {
        'type': 'toolCall',
        'id': 't1',
        'name': 'todo_write',
        'arguments': {'todos': todos},
      },
    ],
  });

void main() {
  test('parses loose statuses and keeps one step in progress', () {
    final items = parseTodos([
      {'content': 'A', 'status': 'done'},
      {'content': 'B', 'status': 'in progress', 'activeForm': 'Doing B'},
      {'content': 'C', 'status': 'in_progress'},
      {'content': ' '},
      {'text': 'D'},
      'x',
    ]);
    expect(items.map((t) => t.content), ['A', 'B', 'C', 'D']);
    expect(items.map((t) => t.status), [
      TodoStatus.completed,
      TodoStatus.inProgress,
      TodoStatus.pending,
      TodoStatus.pending,
    ]);
    expect(items[1].label, 'Doing B');
    final p = TodoPlan(items);
    expect((p.done, p.total, p.currentNumber), (1, 4, 2));
  });

  test('the latest plan shows; a finished one goes once the user writes again', () {
    final unfinished = plan([
      {'content': 'A', 'status': 'completed'},
      {'content': 'B', 'status': 'pending'},
    ]);
    final finished = plan([
      {'content': 'A', 'status': 'completed'},
      {'content': 'B', 'status': 'completed'},
    ]);
    expect(currentPlan([UserEntry('go'), unfinished])!.done, 1);
    expect(currentPlan([UserEntry('go'), unfinished, UserEntry('more')])!.done, 1, reason: 'still has steps to do');
    expect(currentPlan([UserEntry('go'), unfinished, finished])!.finished, true);
    expect(currentPlan([UserEntry('go'), finished, UserEntry('next task')]), isNull);
    expect(currentPlan([UserEntry('hi')]), isNull);
  });

  testWidgets('card and progress bar fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final entry = plan([
      {'content': 'Set up the Vite project with React and TypeScript and Tailwind', 'status': 'completed'},
      {
        'content': 'Build the login page',
        'status': 'in_progress',
        'activeForm': 'Building the login page with a very long description that must wrap or ellipsize',
      },
      {'content': 'Deploy', 'status': 'pending'},
    ]);
    final block = entry.orderedBlocks.last;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TodoCard(block: block),
              const SizedBox(height: 12),
              TodoProgressBar(plan: currentPlan([entry])!),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Deploy'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.textContaining('2/3 · Building the login page'), findsOneWidget);

    // Tapping the bar shows the whole list.
    await tester.tap(find.byType(TodoProgressBar));
    await tester.pumpAndSettle();
    expect(find.text('Deploy'), findsNWidgets(2));
  });
}
