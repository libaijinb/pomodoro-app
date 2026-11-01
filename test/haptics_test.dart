// Verifies vibration calls used by the app do not throw, and that
// tapping a tab (which triggers selectionClick) does not crash.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pomodoro_app/main.dart';

void main() {
  test('haptic feedback calls complete without throwing', () async {
    await HapticFeedback.lightImpact();
    await HapticFeedback.mediumImpact();
    await HapticFeedback.heavyImpact();
    await HapticFeedback.selectionClick();
    await HapticFeedback.vibrate();
  });

  testWidgets('switching tabs (selection haptic) does not crash', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PomodoroApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('25:00'), findsOneWidget);
    await tester.tap(find.text('任务'));
    await tester.pump();
    await tester.tap(find.text('计时'));
    await tester.pump();
    expect(find.text('25:00'), findsOneWidget);
  });
}
