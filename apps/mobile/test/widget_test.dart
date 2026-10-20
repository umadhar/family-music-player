import 'package:flutter_test/flutter_test.dart';
import 'package:kids_music_player/main.dart';

void main() {
  testWidgets('app builds and shows home content', (tester) async {
    await tester.pumpWidget(const KidsMusicPlayerApp());
    await tester.pump();

    expect(find.text('Tiny Tunes'), findsOneWidget);
    expect(find.text('Let the tunes play!'), findsOneWidget);
  });
}
