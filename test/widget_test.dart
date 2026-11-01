// Smoke test for the 番茄钟 app: it should show the title and 25:00.
// Note: pump() (not pumpAndSettle) is used because the loading indicator
// animates continuously while settings are being read.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pomodoro_app/main.dart';

void main() {
  testWidgets('Pomodoro home shows title and default timer', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PomodoroApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('番茄钟'), findsWidgets);
    expect(find.text('25:00'), findsOneWidget);
  });
}
