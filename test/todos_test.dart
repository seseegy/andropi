import 'package:andropi/agent/agent_client.dart';
import 'package:andropi/agent/agent_controller.dart';
import 'package:andropi/agent/models.dart';
import 'package:andropi/agent/todos.dart';
import 'package:andropi/ui/theme.dart';
import 'package:andropi/ui/todo_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

var _ids = 0;

AssistantEntry plan(Object todos, {String? id}) => AssistantEntry()
  ..applyMessage({
    'content': [
      {'type': 'text', 'text': 'On it.'},
      {
        'type': 'toolCall',
        'id': id ?? 't${_ids++}',
        'name': 'todo_write',
        'arguments': {'todos': todos},
      },
    ],
  });

const _unfinished = [
  {'content': 'A', 'status': 'completed'},
  {'content': 'B', 'status': 'pending'},
];
const _finished = [
  {'content': 'A', 'status': 'completed'},
  {'content': 'B', 'status': 'completed'},
];

void main() {
  test('parses loose statuses, JSON strings and "None"', () {
    final items = parseTodos([
      {'content': 'A', 'status': 'done'},
      {'content': 'B', 'status': 'in progress', 'activeForm': 'Doing B'},
      {'content': 'C', 'status': 'in_progress', 'activeForm': 'None'},
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
    expect(items[2].activeForm, isNull);
    expect(parseTodos('[{"content":"X","status":"in_progress"}]').single.status, TodoStatus.inProgress);
    expect(parseTodos('not json'), isEmpty);
    final p = TodoPlan(items);
    expect((p.done, p.total, p.currentNumber), (1, 4, 2));
  });

  test('which plan shows', () {
    // This turn: always, finished or not.
    expect(currentPlan([UserEntry('go'), plan(_unfinished)])!.currentTurn, true);
    expect(currentPlan([UserEntry('go'), plan(_finished)])!.plan.finished, true);
    // An earlier turn: unfinished, for one more message ("carry on"), as paused.
    final carryOn = currentPlan([UserEntry('go'), plan(_unfinished), UserEntry('carry on')])!;
    expect((carryOn.currentTurn, carryOn.plan.done), (false, 1));
    expect(currentPlan([UserEntry('go'), plan(_unfinished), UserEntry('a'), UserEntry('b')]), isNull);
    expect(currentPlan([UserEntry('go'), plan(_finished), UserEntry('next task')]), isNull);
    // Dismissed.
    expect(currentPlan([UserEntry('go'), plan(_unfinished, id: 'p1'), UserEntry('x')], dismissed: {'p1'}), isNull);
    // A failed call doesn't replace the plan before it.
    final failed = plan('garbage', id: 'bad');
    final s = currentPlan(
      [UserEntry('go'), plan(_unfinished), failed],
      tools: {'bad': ToolRun('bad')..status = ToolStatus.failed},
    )!;
    expect(s.plan.total, 2);
    // Compacted away: the saved plan stands in.
    final saved = TodoState(TodoPlan(parseTodos(_unfinished)), id: 's', currentTurn: true);
    final restored = currentPlan([NoticeEntry('Earlier messages were summarized to save context.')], saved: saved)!;
    expect((restored.id, restored.currentTurn), ('s', false));
    expect(currentPlan([UserEntry('hi')], saved: saved), isNull, reason: 'only after compaction');
  });

  group('views', () {
    setUp(() {
      // AgentClient listens to the host's event channel.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('andropi/agent/events'),
        (_) async => null,
      );
    });

    Future<AgentController> show(WidgetTester tester, List<ChatEntry> entries) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final agent = AgentController(AgentClient())..entries.addAll(entries);
      final block = entries.whereType<AssistantEntry>().last.orderedBlocks.last;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: agent,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TodoCard(block: block),
                  const SizedBox(height: 12),
                  TodoProgressBar(agent: agent),
                ],
              ),
            ),
          ),
        ),
      );
      return agent;
    }

    testWidgets('card and bar fit a narrow phone; tap opens the list', (tester) async {
      await show(tester, [
        UserEntry('go'),
        plan([
          {'content': 'Set up the Vite project with React and TypeScript and Tailwind', 'status': 'completed'},
          {
            'content': 'Build the login page',
            'status': 'in_progress',
            'activeForm': 'Building the login page with a very long description that must wrap or ellipsize',
          },
          {'content': 'Deploy', 'status': 'pending'},
        ]),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Deploy'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(find.textContaining('2/3 · Building the login page'), findsOneWidget);
      await tester.tap(find.textContaining('2/3 ·'));
      await tester.pumpAndSettle();
      expect(find.text('Deploy'), findsNWidgets(2));
    });

    testWidgets('a paused plan can be dismissed', (tester) async {
      final agent = await show(tester, [UserEntry('go'), plan(_unfinished), UserEntry('something else')]);
      expect(find.textContaining('Paused'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss plan'));
      await tester.pump();
      expect(agent.todo, isNull);
      expect(find.textContaining('Paused'), findsNothing);
    });
  });
}
