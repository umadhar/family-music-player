import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kids_music_player/main.dart';
import 'package:kids_music_player/music_audio_handler.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockAudioPlayer extends Mock implements AudioPlayer {}

class _LibraryTestModel extends MusicPlayerModel {
  _LibraryTestModel(List<Song> songs, MusicAudioHandler handler)
    : _songs = List.of(songs),
      super(audioHandler: handler);

  final List<Song> _songs;
  String _searchTerm = '';

  @override
  String get searchTerm => _searchTerm;

  @override
  String? get statusMessage => null;

  @override
  List<Song> get songs => List.unmodifiable(_songs);

  @override
  List<Song> get filteredSongs {
    final query = _searchTerm.trim().toLowerCase();
    if (query.isEmpty) return songs;
    return _songs
        .where(
          (song) =>
              song.title.toLowerCase().contains(query) ||
              song.artist.toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  Song? get currentSong => null;

  @override
  bool get isPlaying => false;

  @override
  void setSearchTerm(String value) {
    _searchTerm = value;
    notifyListeners();
  }

  @override
  Future<void> playSong(Song song) async {}

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> toggleFavorite(Song song) async {}

  @override
  Future<void> addSongToPlaylist(Song song, Playlist playlist) async {}

  @override
  Future<void> removeSong(Song song) async {
    _songs.removeWhere((entry) => entry.id == song.id);
    notifyListeners();
  }

  @override
  Future<void> importFiles() async {}
}

void main() {
  late _MockAudioPlayer player;
  late MusicAudioHandler handler;
  late MusicPlayerModel model;
  late Database database;
  late MusicLibraryRepository repository;
  late StreamController<PlaybackEvent> playbackEvents;

  setUpAll(() {
    registerFallbackValue(<AudioSource>[]);
    registerFallbackValue(Duration.zero);
    registerFallbackValue(LoopMode.off);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE songs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            file_path TEXT NOT NULL UNIQUE,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            favorite INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE playlists (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE
          )
        ''');
        await db.execute('''
          CREATE TABLE playlist_songs (
            playlist_id INTEGER NOT NULL,
            song_id INTEGER NOT NULL,
            PRIMARY KEY (playlist_id, song_id)
          )
        ''');
      },
    );
    repository = MusicLibraryRepository(database: database);

    player = _MockAudioPlayer();
    playbackEvents = StreamController<PlaybackEvent>();
    when(
      () => player.playbackEventStream,
    ).thenAnswer((_) => playbackEvents.stream);
    when(
      () => player.currentIndexStream,
    ).thenAnswer((_) => const Stream<int?>.empty());
    when(
      () => player.durationStream,
    ).thenAnswer((_) => const Stream<Duration?>.empty());
    when(
      () => player.errorStream,
    ).thenAnswer((_) => const Stream<PlayerException>.empty());
    when(
      () => player.positionStream,
    ).thenAnswer((_) => const Stream<Duration>.empty());
    when(() => player.playing).thenReturn(false);
    when(() => player.processingState).thenReturn(ProcessingState.ready);
    when(() => player.position).thenReturn(Duration.zero);
    when(() => player.duration).thenReturn(null);
    when(() => player.bufferedPosition).thenReturn(Duration.zero);
    when(() => player.speed).thenReturn(1);
    when(() => player.shuffleModeEnabled).thenReturn(false);
    when(() => player.loopMode).thenReturn(LoopMode.off);
    when(() => player.currentIndex).thenReturn(0);
    when(() => player.hasNext).thenReturn(true);
    when(() => player.hasPrevious).thenReturn(true);
    when(
      () => player.setAudioSources(
        any(),
        initialIndex: any(named: 'initialIndex'),
        preload: any(named: 'preload'),
      ),
    ).thenAnswer((_) async => null);
    when(() => player.setShuffleModeEnabled(any())).thenAnswer((_) async {});
    when(() => player.setLoopMode(any())).thenAnswer((_) async {});
    when(() => player.play()).thenAnswer((_) async {});
    when(() => player.pause()).thenAnswer((_) async {});
    when(() => player.stop()).thenAnswer((_) async {});
    when(
      () => player.seek(any(), index: any(named: 'index')),
    ).thenAnswer((_) async {});
    when(() => player.seekToNext()).thenAnswer((_) async {});
    when(() => player.seekToPrevious()).thenAnswer((_) async {});
    when(() => player.dispose()).thenAnswer((_) async {});
    handler = MusicAudioHandler(player);
    model = MusicPlayerModel(audioHandler: handler, repository: repository);
    await model.initialize();
  });

  tearDown(() async {
    model.dispose();
    await handler.dispose();
    await playbackEvents.close();
    await database.close();
  });

  MediaItem item(int id, String title, String artist) => MediaItem(
    id: '$id',
    title: title,
    artist: artist,
    extras: {'filePath': '/music/$id.mp3'},
  );

  test('publishes queue metadata and selected item', () async {
    final first = item(11, 'Morning Song', 'The Band');
    final second = item(12, 'Evening Song', 'Another Artist');

    await handler.setQueue([first, second], startIndex: 1);

    expect(handler.queue.value, [first, second]);
    expect(handler.mediaItem.value, second);
    verify(
      () => player.setAudioSources(any(), initialIndex: 1, preload: false),
    ).called(1);
  });

  test('maps library track data to stable local media metadata', () {
    final knownMetadata = createMediaItemForSong(
      const Song(
        id: 21,
        title: 'Story Time',
        artist: 'The Singers',
        filePath: '/music/story_time.mp3',
        durationMs: 95000,
        isFavorite: false,
      ),
    );
    final filenameFallback = createMediaItemForSong(
      const Song(
        id: 22,
        title: 'Untitled track',
        artist: 'Local track',
        filePath: '/music/a_song_file.mp3',
        durationMs: 0,
        isFavorite: false,
      ),
    );

    expect(knownMetadata.id, '21');
    expect(knownMetadata.title, 'Story Time');
    expect(knownMetadata.artist, 'The Singers');
    expect(knownMetadata.duration, const Duration(milliseconds: 95000));
    expect(knownMetadata.extras?['filePath'], '/music/story_time.mp3');
    expect(filenameFallback.title, 'a song file');
    expect(filenameFallback.artist, 'Local track');
    expect(filenameFallback.duration, isNull);
  });

  test('routes play and pause to the existing player', () async {
    await handler.setQueue([item(1, 'Song', 'Artist')]);

    await handler.play();
    await handler.pause();

    verify(() => player.play()).called(1);
    verify(() => player.pause()).called(1);
  });

  test(
    'publishes the current playback state and notification control',
    () async {
      when(() => player.playing).thenReturn(true);
      await handler.setQueue([item(1, 'Song', 'Artist')]);

      playbackEvents.add(PlaybackEvent(processingState: ProcessingState.ready));
      await Future<void>.delayed(Duration.zero);

      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.controls[1], MediaControl.pause);
    },
  );

  test('previous and next navigate the active queue', () async {
    await handler.setQueue([
      item(1, 'First', 'Artist'),
      item(2, 'Second', 'Artist'),
    ]);

    await handler.skipToNext();
    await handler.skipToPrevious();

    verify(() => player.seekToNext()).called(1);
    verify(() => player.seekToPrevious()).called(1);
    verify(() => player.play()).called(2);
  });

  test('queue modes reach the same player', () async {
    await handler.setQueue(
      [item(1, 'First', 'Artist'), item(2, 'Second', 'Artist')],
      shuffleEnabled: true,
      repeatEnabled: true,
    );

    verify(() => player.setShuffleModeEnabled(true)).called(1);
    verify(() => player.setLoopMode(LoopMode.all)).called(1);
  });

  test(
    'next at the end restarts the current track when repeat is off',
    () async {
      when(() => player.hasNext).thenReturn(false);
      when(() => player.currentIndex).thenReturn(1);
      await handler.setQueue([
        item(1, 'First', 'Artist'),
        item(2, 'Second', 'Artist'),
      ]);

      await handler.skipToNext();

      verify(() => player.seek(Duration.zero, index: 1)).called(1);
      verify(() => player.play()).called(1);
    },
  );

  test('empty queues clear metadata and safely ignore controls', () async {
    await handler.setQueue([]);

    expect(handler.queue.value, isEmpty);
    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );

    await handler.play();
    await handler.skipToNext();
    await handler.skipToPrevious();
    await handler.seek(const Duration(seconds: 5));

    verifyNever(() => player.play());
    verifyNever(() => player.seekToNext());
    verifyNever(() => player.seekToPrevious());
  });

  test(
    'library removal clears favorites and playlist links only for that song',
    () async {
      final removedId = await database.insert('songs', {
        'title': 'Favorite Song',
        'artist': 'Artist',
        'file_path': '/music/favorite.mp3',
        'favorite': 1,
      });
      final retainedId = await database.insert('songs', {
        'title': 'Keep This Song',
        'artist': 'Artist',
        'file_path': '/music/keep.mp3',
        'favorite': 0,
      });
      await repository.createPlaylist('Road Trip');
      final playlist = (await repository.getPlaylists()).singleWhere(
        (entry) => entry.name == 'Road Trip',
      );
      await repository.addSongToPlaylist(removedId, playlist.id);
      await repository.addSongToPlaylist(retainedId, playlist.id);
      await model.refresh();

      final song = model.songs.singleWhere((entry) => entry.id == removedId);
      await model.removeSong(song);

      expect(model.songs.map((entry) => entry.id), [retainedId]);
      expect(model.favorites, isEmpty);
      expect(
        (await repository.getSongsForPlaylist(
          playlist.id,
        )).map((entry) => entry.id),
        [retainedId],
      );
      expect(
        (await repository.getPlaylists()).map((entry) => entry.name),
        containsAll(['Favorites', 'Road Trip']),
      );
    },
  );

  test('removing the playing library song advances the active queue', () async {
    final firstId = await database.insert('songs', {
      'title': 'Playing Song',
      'artist': 'Artist',
      'file_path': '/music/playing.mp3',
      'favorite': 0,
    });
    final nextId = await database.insert('songs', {
      'title': 'Next Song',
      'artist': 'Artist',
      'file_path': '/music/next.mp3',
      'favorite': 0,
    });
    await model.refresh();
    final first = model.songs.singleWhere((song) => song.id == firstId);
    final next = model.songs.singleWhere((song) => song.id == nextId);
    when(() => player.playing).thenReturn(true);
    await handler.setQueue([
      createMediaItemForSong(first),
      createMediaItemForSong(next),
    ]);

    await model.removeSong(first);

    expect(handler.queue.value.map((item) => item.id), [nextId.toString()]);
    expect(handler.currentMediaItem?.id, nextId.toString());
    expect(model.currentSong?.id, nextId);
    verify(() => player.play()).called(1);
  });

  test(
    'removing the last song stops playback and leaves an empty library',
    () async {
      final onlyId = await database.insert('songs', {
        'title': 'Only Song',
        'artist': 'Artist',
        'file_path': '/music/only.mp3',
        'favorite': 0,
      });
      await model.refresh();
      final onlySong = model.songs.single;
      await handler.setQueue([createMediaItemForSong(onlySong)]);

      await model.removeSong(onlySong);

      expect(model.songs, isEmpty);
      expect(model.currentSong, isNull);
      expect(handler.queue.value, isEmpty);
      expect(handler.currentMediaItem, isNull);
      expect(
        await database.query('songs', where: 'id = ?', whereArgs: [onlyId]),
        isEmpty,
      );
      verify(() => player.stop()).called(1);
    },
  );

  testWidgets(
    'library removal requires confirmation and supports cancellation',
    (tester) async {
      const song = Song(
        id: 101,
        title: 'A Song to Keep',
        artist: 'Artist',
        filePath: '/music/keep_this.mp3',
        durationMs: 0,
        isFavorite: false,
      );
      final libraryModel = _LibraryTestModel([song], handler);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: libraryModel,
              builder: (context, child) => LibraryTab(model: libraryModel),
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('More song options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Remove from library'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Remove song from library?'), findsOneWidget);
      expect(
        find.textContaining('The audio file will not be deleted.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(libraryModel.songs.single.id, song.id);
      expect(find.text(song.title), findsOneWidget);

      await tester.tap(find.byTooltip('More song options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Remove from library'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Remove song'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(libraryModel.songs, isEmpty);
      expect(find.text('Your song shelf is waiting!'), findsOneWidget);
      libraryModel.dispose();
    },
  );

  testWidgets('library tiles handle long titles and missing metadata', (
    tester,
  ) async {
    const longTitle =
        'A Very Long Song Title That Should Wrap Without Breaking the Layout';
    final libraryModel = _LibraryTestModel(const [
      Song(
        id: 102,
        title: longTitle,
        artist: 'Artist',
        filePath: '/music/long-title.mp3',
        durationMs: 0,
        isFavorite: false,
      ),
      Song(
        id: 103,
        title: 'Untitled track',
        artist: 'Local track',
        filePath: '/music/a_missing_metadata_track.mp3',
        durationMs: 0,
        isFavorite: false,
      ),
    ], handler);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: libraryModel,
            builder: (context, child) => LibraryTab(model: libraryModel),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(longTitle), findsOneWidget);
    expect(find.text('a missing metadata track'), findsOneWidget);
    expect(tester.takeException(), isNull);
    libraryModel.setSearchTerm('no such song');
    await tester.pump();
    expect(find.text('No tunes found'), findsOneWidget);
    libraryModel.setSearchTerm('');
    await tester.pump();
    expect(find.text('Your song shelf is waiting!'), findsNothing);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    libraryModel.dispose();
  });

  test('removing the current song continues with the next song', () async {
    final first = item(1, 'First', 'Artist');
    final second = item(2, 'Second', 'Artist');
    when(() => player.playing).thenReturn(true);
    await handler.setQueue([first, second]);

    await handler.removeFromQueue(first.id);

    expect(handler.queue.value, [second]);
    expect(handler.currentMediaItem, second);
    verify(() => player.play()).called(1);
    verify(
      () => player.setAudioSources(any(), initialIndex: 0, preload: false),
    ).called(2);
  });

  test('removing the current song while paused stays paused', () async {
    final first = item(1, 'First', 'Artist');
    final second = item(2, 'Second', 'Artist');
    await handler.setQueue([first, second]);

    await handler.removeFromQueue(first.id);

    expect(handler.queue.value, [second]);
    expect(handler.currentMediaItem, second);
    verifyNever(() => player.play());
  });

  test('removing the last queued song clears the player queue', () async {
    await handler.setQueue([item(1, 'Only song', 'Artist')]);

    await handler.removeFromQueue('1');

    expect(handler.queue.value, isEmpty);
    expect(handler.currentMediaItem, isNull);
    verify(() => player.setAudioSources(const [], preload: false)).called(1);
    verify(() => player.stop()).called(1);
  });
}
