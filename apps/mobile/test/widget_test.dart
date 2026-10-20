import 'package:just_audio/just_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kids_music_player/main.dart';
import 'package:kids_music_player/music_audio_handler.dart';

void main() {
  testWidgets('app builds and shows home content', (tester) async {
    final audioHandler = MusicAudioHandler(AudioPlayer());

    await tester.pumpWidget(KidsMusicPlayerApp(audioHandler: audioHandler));
    await tester.pump();

    expect(find.text('Tiny Tunes'), findsOneWidget);
    expect(find.text('Let the tunes play!'), findsOneWidget);
  });
}
