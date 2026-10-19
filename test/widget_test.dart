import 'package:flutter_test/flutter_test.dart';
import 'package:tryzub_app/main.dart';

void main() {
  testWidgets('TryzubApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TryzubApp());
    expect(find.byType(TryzubApp), findsOneWidget);
  });
}
