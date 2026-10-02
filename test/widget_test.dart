import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mynet/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const App());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}