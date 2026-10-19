import 'dart:async';

import 'package:andropi/ui/task_log.dart';
import 'package:andropi/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('back does not close a running task, and does once it is done', (tester) async {
    final done = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => runWithLog<String>(context, title: 'Deploying', task: (log, ci) => done.future),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    // The spinner never settles while the task runs.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Deploying'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Deploying'), findsOneWidget);

    done.complete('ok');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Deploying'), findsNothing);
  });
}
