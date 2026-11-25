import 'package:flutter_test/flutter_test.dart';
import 'package:qjs_dot_example/main.dart';

void main() {
  testWidgets('renders playground title', (WidgetTester tester) async {
    await tester.pumpWidget(const QjsDotExampleApp(autoInit: false));
    expect(find.text('qjs-dot Playground'), findsOneWidget);
  });
}
