import 'package:andropi/ui/message_menu.dart';
import 'package:andropi/ui/message_views.dart';
import 'package:andropi/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const actions = [
    MessageAction('copy', 'Copy', Icons.copy),
    MessageAction('edit', 'Edit & resend', Icons.edit),
    MessageAction('fork', 'Fork from here', Icons.call_split),
  ];

  Future<Future<String?> Function()> harness(WidgetTester tester, String text, {double top = 100}) async {
    String? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                top: top,
                right: 16,
                width: 300,
                child: Builder(
                  builder: (bubbleContext) => GestureDetector(
                    onLongPress: () async {
                      result = await showMessageMenu(bubbleContext, bubble: UserBubble(text), actions: actions);
                      done = true;
                    },
                    child: UserBubble(text),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return () async {
      while (!done) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return result;
    };
  }

  testWidgets('long-press opens the menu and returns the tapped action', (tester) async {
    final result = await harness(tester, 'Fix the login bug');
    await tester.pump();
    await tester.longPress(find.byType(UserBubble).first);
    await tester.pumpAndSettle();
    expect(find.text('Edit & resend'), findsOneWidget);
    // The bubble is shown twice: in the chat and lifted above the blur.
    expect(find.byType(UserBubble), findsNWidgets(2));
    await tester.tap(find.text('Fork from here'));
    await tester.pumpAndSettle();
    expect(await result(), 'fork');
    expect(find.text('Edit & resend'), findsNothing);
  });

  testWidgets('tapping outside closes it without an action', (tester) async {
    final result = await harness(tester, 'Hello');
    await tester.pump();
    await tester.longPress(find.byType(UserBubble).first);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(await result(), isNull);
  });

  testWidgets('a long message near the bottom keeps the whole menu on screen', (tester) async {
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final result = await harness(tester, List.filled(80, 'a long line of text').join('\n'), top: screen.height - 300);
    await tester.pump();
    // The bubble runs off the bottom; press its visible top.
    await tester.longPressAt(tester.getTopLeft(find.byType(UserBubble).first) + const Offset(20, 20));
    await tester.pumpAndSettle();
    for (final label in ['Copy', 'Edit & resend', 'Fork from here']) {
      final r = tester.getRect(find.text(label));
      expect(r.top >= 0 && r.bottom <= screen.height, isTrue, reason: '$label at $r');
    }
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(await result(), 'copy');
  });

  testWidgets('a narrow, short screen lays out without errors', (tester) async {
    tester.view.physicalSize = const Size(200, 220);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final result = await harness(tester, 'Hi', top: 20);
    await tester.pump();
    await tester.longPress(find.byType(UserBubble).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('Copy')).right, lessThanOrEqualTo(200));
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await result(), isNull);
  });
}
