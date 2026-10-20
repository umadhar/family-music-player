import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'music_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final audioHandler = Platform.isAndroid
      ? await AudioService.init<MusicAudioHandler>(
          builder: () => MusicAudioHandler(AudioPlayer()),
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'com.example.kids_music_player.audio',
            androidNotificationChannelName: 'Tiny Tunes playback',
            androidNotificationChannelDescription:
                'Playback controls for your local music library.',
            androidNotificationOngoing: true,
            androidStopForegroundOnPause: true,
          ),
        )
      : MusicAudioHandler(AudioPlayer());

  runApp(KidsMusicPlayerApp(audioHandler: audioHandler));
}

class KidsMusicPlayerApp extends StatelessWidget {
  const KidsMusicPlayerApp({required this.audioHandler, super.key});

  final MusicAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MusicPlayerModel(audioHandler: audioHandler)..initialize(),
      child: MaterialApp(
        title: 'Tiny Tunes',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF8D6AE8),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF8F3FF),
          appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
        ),
        home: const MainShell(),
      ),
    );
  }
}

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.filePath,
    required this.durationMs,
    required this.isFavorite,
  });

  final int id;
  final String title;
  final String artist;
  final String filePath;
  final int durationMs;
  final bool isFavorite;

  String get durationLabel {
    if (durationMs <= 0) return '—';
    final minutes = (durationMs / 60000).floor();
    final seconds = ((durationMs % 60000) / 1000).round();
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get leadingLetter => title.isNotEmpty ? title[0].toUpperCase() : 'M';

  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as int,
      title: (map['title'] ?? 'Untitled track') as String,
      artist: (map['artist'] ?? 'Local track') as String,
      filePath: (map['file_path'] ?? '') as String,
      durationMs: (map['duration_ms'] ?? 0) as int,
      isFavorite: (map['favorite'] ?? 0) == 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'artist': artist,
      'file_path': filePath,
      'duration_ms': durationMs,
      'favorite': isFavorite ? 1 : 0,
    };
  }
}

MediaItem createMediaItemForSong(Song song) {
  final fileTitle = p
      .basenameWithoutExtension(song.filePath)
      .replaceAll('_', ' ')
      .trim();
  final title = song.title.trim();
  final notificationTitle = title.isEmpty || title == 'Untitled track'
      ? fileTitle
      : title;

  return MediaItem(
    id: song.id.toString(),
    title: notificationTitle.isEmpty ? 'Untitled track' : notificationTitle,
    artist: song.artist.trim().isEmpty ? 'Local track' : song.artist.trim(),
    duration: song.durationMs > 0
        ? Duration(milliseconds: song.durationMs)
        : null,
    extras: {'filePath': song.filePath},
  );
}

class Playlist {
  const Playlist({required this.id, required this.name});

  final int id;
  final String name;

  factory Playlist.fromMap(Map<String, dynamic> map) {
    return Playlist(id: map['id'] as int, name: map['name'] as String);
  }
}

class MusicLibraryRepository {
  MusicLibraryRepository({Database? database}) : _database = database;

  Database? _database;

  Future<Database> get database async {
    _database ??= await _openDatabase();
    return _database!;
  }

  Future<Database> _openDatabase() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final databasesPath = await getDatabasesPath();
    final path = p.join(databasesPath, 'kids_music_player.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => _createTables(db),
    );
  }

  Future<void> _createTables(DatabaseExecutor db) async {
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
  }

  Future<void> initialize() async {
    final db = await database;
    final existing = await db.query(
      'playlists',
      where: 'name = ?',
      whereArgs: ['Favorites'],
    );
    if (existing.isEmpty) {
      await db.insert('playlists', {'name': 'Favorites'});
    }
  }

  Future<List<Song>> getSongs() async {
    final db = await database;
    final rows = await db.query('songs', orderBy: 'id DESC');
    return rows.map(Song.fromMap).toList();
  }

  Future<List<Playlist>> getPlaylists() async {
    final db = await database;
    final rows = await db.query('playlists', orderBy: 'name ASC');
    return rows.map(Playlist.fromMap).toList();
  }

  Future<List<Song>> getSongsForPlaylist(int playlistId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
        SELECT s.*
        FROM songs s
        INNER JOIN playlist_songs ps ON ps.song_id = s.id
        WHERE ps.playlist_id = ?
        ORDER BY s.title ASC
      ''',
      [playlistId],
    );
    return rows.map(Song.fromMap).toList();
  }

  Future<List<Song>> getFavoriteSongs() async {
    final db = await database;
    final rows = await db.query(
      'songs',
      where: 'favorite = 1',
      orderBy: 'title ASC',
    );
    return rows.map(Song.fromMap).toList();
  }

  Future<Song?> importSongFromSource(String sourcePath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      return null;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final musicDir = Directory(p.join(appDir.path, 'library'));
    if (!await musicDir.exists()) {
      await musicDir.create(recursive: true);
    }

    final originalName = p.basename(sourcePath);
    final cleanName = originalName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final destinationPath = p.join(
      musicDir.path,
      '${DateTime.now().millisecondsSinceEpoch}_$cleanName',
    );

    final destinationFile = await sourceFile.copy(destinationPath);
    final title = p
        .basenameWithoutExtension(originalName)
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
    final song = Song(
      id: 0,
      title: title.isEmpty ? 'Untitled track' : title,
      artist: 'Local track',
      filePath: destinationFile.path,
      durationMs: 0,
      isFavorite: false,
    );

    final db = await database;
    final existing = await db.query(
      'songs',
      where: 'file_path = ?',
      whereArgs: [destinationFile.path],
    );
    if (existing.isNotEmpty) {
      return null;
    }

    final id = await db.insert('songs', song.toMap());
    return Song(
      id: id,
      title: song.title,
      artist: song.artist,
      filePath: song.filePath,
      durationMs: song.durationMs,
      isFavorite: song.isFavorite,
    );
  }

  Future<void> createPlaylist(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final db = await database;
    await db.insert('playlists', {'name': trimmed});
  }

  Future<void> renamePlaylist(int id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final db = await database;
    await db.update(
      'playlists',
      {'name': trimmed},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlaylist(int id) async {
    final db = await database;
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [id],
    );
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> addSongToPlaylist(int songId, int playlistId) async {
    final db = await database;
    await db.insert('playlist_songs', {
      'playlist_id': playlistId,
      'song_id': songId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeSongFromPlaylist(int songId, int playlistId) async {
    final db = await database;
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ? AND song_id = ?',
      whereArgs: [playlistId, songId],
    );
  }

  Future<void> removeSong(int songId) async {
    final db = await database;
    await db.transaction((transaction) async {
      final deleted = await transaction.delete(
        'songs',
        where: 'id = ?',
        whereArgs: [songId],
      );
      if (deleted == 0) {
        throw StateError('This song is no longer in your library.');
      }
      await transaction.delete(
        'playlist_songs',
        where: 'song_id = ?',
        whereArgs: [songId],
      );
    });
  }

  Future<void> toggleFavorite(int songId) async {
    final db = await database;
    final rows = await db.query('songs', where: 'id = ?', whereArgs: [songId]);
    if (rows.isEmpty) return;

    final current = (rows.first['favorite'] ?? 0) as int;
    await db.update(
      'songs',
      {'favorite': current == 1 ? 0 : 1},
      where: 'id = ?',
      whereArgs: [songId],
    );
  }

  Future<void> updateDuration(int songId, int durationMs) async {
    final db = await database;
    await db.update(
      'songs',
      {'duration_ms': durationMs},
      where: 'id = ?',
      whereArgs: [songId],
    );
  }

  Future<List<Song>> searchSongs(String query) async {
    final sanitized = query.trim();
    if (sanitized.isEmpty) return getSongs();

    final db = await database;
    final rows = await db.query(
      'songs',
      where: 'title LIKE ? OR artist LIKE ?',
      whereArgs: ['%$sanitized%', '%$sanitized%'],
      orderBy: 'title ASC',
    );
    return rows.map(Song.fromMap).toList();
  }
}

class MusicPlayerModel extends ChangeNotifier {
  MusicPlayerModel({
    required this.audioHandler,
    MusicLibraryRepository? repository,
  }) : _repository = repository ?? MusicLibraryRepository();

  final MusicAudioHandler audioHandler;
  final MusicLibraryRepository _repository;

  final List<Song> _songs = [];
  final List<Playlist> _playlists = [];
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String _searchTerm = '';
  bool _isReady = false;
  String? _statusMessage;

  bool get isReady => _isReady;
  String get searchTerm => _searchTerm;
  List<Song> get songs => List.unmodifiable(_songs);
  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<Song> get favorites => _songs.where((song) => song.isFavorite).toList();
  List<Song> get filteredSongs {
    final query = _searchTerm.trim();
    if (query.isEmpty) return List.unmodifiable(_songs);

    return _songs
        .where(
          (song) =>
              song.title.toLowerCase().contains(query.toLowerCase()) ||
              song.artist.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
  }

  Song? get currentSong {
    final item = audioHandler.currentMediaItem;
    if (item == null) return null;
    final id = int.tryParse(item.id);
    if (id == null) return null;
    for (final song in _songs) {
      if (song.id == id) return song;
    }
    return null;
  }

  bool get isPlaying => audioHandler.playbackState.value.playing;
  bool get shuffleEnabled => audioHandler.shuffleEnabled;
  bool get repeatEnabled => audioHandler.repeatEnabled;
  Duration get position => audioHandler.position;
  Duration? get duration => audioHandler.duration;
  String? get statusMessage => _statusMessage;

  Future<void> initialize() async {
    await _repository.initialize();
    await refresh();

    _subscriptions.add(
      audioHandler.playbackState.listen((state) {
        if (state.processingState == AudioProcessingState.error) {
          _statusMessage =
              'Playback error: ${state.errorMessage ?? 'Unknown error'}';
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(audioHandler.mediaItem.listen((_) => notifyListeners()));
    _subscriptions.add(
      audioHandler.positionStream.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      audioHandler.durationStream.listen((value) {
        if (value != null && value.inMilliseconds > 0) {
          final song = currentSong;
          if (song != null && song.durationMs != value.inMilliseconds) {
            _persistDuration(song, value.inMilliseconds);
          }
        }
        notifyListeners();
      }),
    );

    _isReady = true;
    notifyListeners();
  }

  Future<void> _persistDuration(Song song, int durationMs) async {
    try {
      await _repository.updateDuration(song.id, durationMs);
      final index = _songs.indexWhere((entry) => entry.id == song.id);
      if (index >= 0) {
        _songs[index] = Song(
          id: song.id,
          title: song.title,
          artist: song.artist,
          filePath: song.filePath,
          durationMs: durationMs,
          isFavorite: song.isFavorite,
        );
      }
      notifyListeners();
    } on DatabaseException catch (error) {
      _statusMessage = 'Unable to save track duration: $error';
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final songs = await _repository.getSongs();
    final playlists = await _repository.getPlaylists();

    _songs
      ..clear()
      ..addAll(songs);
    _playlists
      ..clear()
      ..addAll(playlists);
    notifyListeners();
  }

  void setSearchTerm(String value) {
    _searchTerm = value;
    notifyListeners();
  }

  Future<void> importFiles() async {
    final selectedFiles = await FilePicker.pickFiles(type: FileType.audio);

    if (selectedFiles.isEmpty) return;

    final imported = <Song>[];
    for (final file in selectedFiles) {
      final path = file.path;
      if (path == null || path.isEmpty) {
        _statusMessage =
            'Some audio files could not be imported. Please try again.';
        continue;
      }

      final song = await _repository.importSongFromSource(path);
      if (song != null) {
        imported.add(song);
      }
    }

    if (imported.isNotEmpty) {
      _statusMessage = '${imported.length} song(s) added to your library.';
    }

    await refresh();
    notifyListeners();
  }

  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;

    final safeRequestedIndex = startIndex.clamp(0, songs.length - 1);
    final playableSongs = <Song>[];
    var missingCount = 0;
    for (final song in songs) {
      try {
        if (song.filePath.isNotEmpty && await File(song.filePath).exists()) {
          playableSongs.add(song);
        } else {
          missingCount++;
        }
      } on FileSystemException {
        missingCount++;
      }
    }

    if (playableSongs.isEmpty) {
      await audioHandler.setQueue([]);
      _statusMessage = 'No playable audio files were found in this queue.';
      notifyListeners();
      return;
    }

    final requestedSongId = songs[safeRequestedIndex].id;
    var playableStartIndex = playableSongs.indexWhere(
      (song) => song.id == requestedSongId,
    );
    if (playableStartIndex < 0) {
      playableStartIndex = playableSongs.indexWhere(
        (song) =>
            songs.indexWhere((requestedSong) => requestedSong.id == song.id) >
            safeRequestedIndex,
      );
      if (playableStartIndex < 0) playableStartIndex = 0;
    }

    final items = playableSongs
        .map(createMediaItemForSong)
        .toList(growable: false);
    final started = await _runPlaybackAction(() async {
      await audioHandler.setQueue(
        items,
        startIndex: playableStartIndex,
        shuffleEnabled: shuffleEnabled,
        repeatEnabled: repeatEnabled,
      );
      await audioHandler.play();
    });
    if (started) {
      _statusMessage = missingCount > 0
          ? 'Some missing tracks were skipped. Now playing ${playableSongs[playableStartIndex].title}.'
          : 'Now playing ${playableSongs[playableStartIndex].title}';
      notifyListeners();
    }
  }

  Future<bool> _runPlaybackAction(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on PlayerException catch (error) {
      _statusMessage = 'Unable to play this track: ${error.message}';
    } on PlayerInterruptedException catch (error) {
      _statusMessage = 'Playback was interrupted: ${error.message}';
    } on PlatformException catch (error) {
      _statusMessage = 'Playback error: ${error.message ?? error.code}';
    }
    notifyListeners();
    return false;
  }

  Future<void> playSong(Song song) async {
    final queue = filteredSongs.isNotEmpty ? filteredSongs : songs;
    final index = queue.indexWhere((entry) => entry.id == song.id);
    await playQueue(queue, startIndex: index >= 0 ? index : 0);
  }

  Future<void> togglePlayPause() async {
    if (currentSong == null) {
      if (_songs.isNotEmpty) {
        await playQueue(_songs, startIndex: 0);
      }
      return;
    }

    await _runPlaybackAction(
      isPlaying ? audioHandler.pause : audioHandler.play,
    );
    notifyListeners();
  }

  Future<void> nextTrack() async {
    if (audioHandler.queue.value.isEmpty) {
      if (_songs.isNotEmpty) await playQueue(_songs, startIndex: 0);
      return;
    }
    await _runPlaybackAction(audioHandler.skipToNext);
    notifyListeners();
  }

  Future<void> previousTrack() async {
    await _runPlaybackAction(audioHandler.skipToPrevious);
    notifyListeners();
  }

  Future<void> toggleFavorite(Song song) async {
    await _repository.toggleFavorite(song.id);
    final index = _songs.indexWhere((entry) => entry.id == song.id);
    if (index >= 0) {
      final updatedSong = Song(
        id: song.id,
        title: song.title,
        artist: song.artist,
        filePath: song.filePath,
        durationMs: song.durationMs,
        isFavorite: !song.isFavorite,
      );
      _songs[index] = updatedSong;
    }
    notifyListeners();
  }

  Future<void> removeSong(Song song) async {
    await _repository.removeSong(song.id);
    _songs.removeWhere((entry) => entry.id == song.id);
    notifyListeners();
    try {
      await audioHandler.removeFromQueue(song.id.toString());
    } catch (error) {
      _statusMessage =
          'Song removed from the library, but playback could not be updated: $error';
      notifyListeners();
      rethrow;
    }

    _statusMessage = '${song.title} was removed from your library.';
    await refresh();
  }

  Future<void> seekTo(Duration value) async {
    await _runPlaybackAction(() => audioHandler.seek(value));
    notifyListeners();
  }

  Future<void> createPlaylist(String name) async {
    await _repository.createPlaylist(name);
    await refresh();
  }

  Future<void> renamePlaylist(Playlist playlist, String name) async {
    await _repository.renamePlaylist(playlist.id, name);
    await refresh();
  }

  Future<void> deletePlaylist(Playlist playlist) async {
    await _repository.deletePlaylist(playlist.id);
    await refresh();
  }

  Future<void> addSongToPlaylist(Song song, Playlist playlist) async {
    await _repository.addSongToPlaylist(song.id, playlist.id);
    notifyListeners();
  }

  Future<void> removeSongFromPlaylist(Song song, Playlist playlist) async {
    await _repository.removeSongFromPlaylist(song.id, playlist.id);
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    await audioHandler.setShuffleMode(
      shuffleEnabled
          ? AudioServiceShuffleMode.none
          : AudioServiceShuffleMode.all,
    );
    notifyListeners();
  }

  Future<void> toggleRepeat() async {
    await audioHandler.setRepeatMode(
      repeatEnabled ? AudioServiceRepeatMode.none : AudioServiceRepeatMode.all,
    );
    notifyListeners();
  }

  Future<List<Song>> songsForPlaylist(Playlist playlist) async {
    return _repository.getSongsForPlaylist(playlist.id);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final model = context.watch<MusicPlayerModel>();

    final pages = <Widget>[
      HomeTab(model: model),
      LibraryTab(model: model),
      PlaylistTab(model: model),
      FavoritesTab(model: model),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_navTitle(_selectedIndex)),
        actions: [
          if (_selectedIndex == 1)
            IconButton(
              onPressed: () => model.importFiles(),
              icon: const Icon(Icons.file_upload_outlined),
            ),
        ],
      ),
      body: pages[_selectedIndex],
      floatingActionButton: _selectedIndex == 2
          ? FloatingActionButton.extended(
              onPressed: () => _createPlaylist(context),
              icon: const Icon(Icons.add),
              label: const Text('Playlist'),
            )
          : null,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (model.currentSong != null) MiniPlayer(model: model),
          BottomNavigationBar(
            currentIndex: _selectedIndex,
            onTap: (index) => setState(() => _selectedIndex = index),
            type: BottomNavigationBarType.fixed,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.library_music_outlined),
                label: 'Library',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.playlist_play),
                label: 'Playlists',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.favorite_border),
                label: 'Favorites',
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _navTitle(int index) {
    switch (index) {
      case 1:
        return 'Library';
      case 2:
        return 'Playlists';
      case 3:
        return 'Favorites';
      default:
        return 'Tiny Tunes';
    }
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('New playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Playlist name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (result != null && result.trim().isNotEmpty) {
      if (!context.mounted) return;
      await context.read<MusicPlayerModel>().createPlaylist(result.trim());
    }
  }
}

class HomeTab extends StatelessWidget {
  const HomeTab({required this.model, super.key});

  final MusicPlayerModel model;

  @override
  Widget build(BuildContext context) {
    final favoriteSongs = model.favorites;
    final count = model.songs.length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFB9F6CA),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Let the tunes play!',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'You have $count ready-to-play song${count == 1 ? '' : 's'} in your library.',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () => model.playQueue(model.songs),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play all'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => model.importFiles(),
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('Import'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                title: 'Library',
                value: '${model.songs.length}',
                color: Colors.orange,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                title: 'Favorites',
                value: '${favoriteSongs.length}',
                color: Colors.pink,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                title: 'Playlists',
                value: '${model.playlists.length}',
                color: Colors.blue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Favorite picks',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        if (favoriteSongs.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Tap the heart on a song to add it to your favorites playlist.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          )
        else
          ...favoriteSongs
              .take(4)
              .map(
                (song) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.purple.shade100,
                    child: Text(song.leadingLetter),
                  ),
                  title: Text(song.title),
                  subtitle: Text(song.artist),
                  trailing: IconButton(
                    onPressed: () => model.toggleFavorite(song),
                    icon: Icon(
                      song.isFavorite ? Icons.favorite : Icons.favorite_border,
                      color: Colors.pink,
                    ),
                  ),
                  onTap: () => model.playSong(song),
                ),
              ),
      ],
    );
  }
}

class LibraryTab extends StatelessWidget {
  const LibraryTab({required this.model, super.key});

  final MusicPlayerModel model;

  @override
  Widget build(BuildContext context) {
    final songs = model.filteredSongs;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: TextField(
            onChanged: model.setSearchTerm,
            decoration: InputDecoration(
              hintText: 'Search songs or artists',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (model.statusMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              model.statusMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 12,
              ),
            ),
          ),
        Expanded(
          child: songs.isEmpty
              ? _LibraryEmptyState(
                  hasSearch: model.searchTerm.trim().isNotEmpty,
                  onClearSearch: () => model.setSearchTerm(''),
                  onImport: model.importFiles,
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  itemCount: songs.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return _LibrarySongTile(
                      song: song,
                      isCurrent: model.currentSong?.id == song.id,
                      isPlaying: model.isPlaying,
                      onPlay: () => model.playSong(song),
                      onTogglePlayback: model.togglePlayPause,
                      onAction: (action) => _handleLibrarySongAction(
                        context,
                        model,
                        song,
                        action,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _LibrarySongTile extends StatelessWidget {
  const _LibrarySongTile({
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    required this.onPlay,
    required this.onTogglePlayback,
    required this.onAction,
  });

  final Song song;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onTogglePlayback;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final metadata = <String>[
      if (song.artist.trim().isNotEmpty && song.artist != 'Local track')
        song.artist.trim(),
      if (song.durationMs > 0) song.durationLabel,
      if (isCurrent) isPlaying ? 'Now playing' : 'Paused',
    ];

    return Card(
      margin: EdgeInsets.zero,
      color: isCurrent
          ? Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: 0.7)
          : Colors.white,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isCurrent
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
              : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 82,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: _SongArtwork(song: song, isCurrent: isCurrent),
        title: Text(
          _songDisplayTitle(song),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
            fontSize: 15,
          ),
        ),
        subtitle: metadata.isEmpty
            ? null
            : Text(
                metadata.join('  •  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              tooltip: isCurrent && isPlaying ? 'Pause' : 'Play',
              visualDensity: VisualDensity.compact,
              onPressed: isCurrent && isPlaying ? onTogglePlayback : onPlay,
              icon: Icon(
                isCurrent && isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More song options',
              onSelected: onAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'favorite',
                  child: Text(
                    song.isFavorite
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                  ),
                ),
                const PopupMenuItem(
                  value: 'playlist',
                  child: Text('Add to playlist'),
                ),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove from library'),
                ),
              ],
            ),
          ],
        ),
        onTap: isCurrent && isPlaying ? onTogglePlayback : onPlay,
      ),
    );
  }
}

class _SongArtwork extends StatelessWidget {
  const _SongArtwork({required this.song, required this.isCurrent});

  final Song song;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    const colors = [
      Color(0xFFFFD6A5),
      Color(0xFFCAFFBF),
      Color(0xFFA0C4FF),
      Color(0xFFFFADAD),
      Color(0xFFE4C1F9),
    ];
    final color = colors[song.id.abs() % colors.length];

    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        isCurrent ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
        color: const Color(0xFF4D3E68),
        size: 27,
      ),
    );
  }
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState({
    required this.hasSearch,
    required this.onClearSearch,
    required this.onImport,
  });

  final bool hasSearch;
  final VoidCallback onClearSearch;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: const Color(0xFFE8DEFF),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                hasSearch
                    ? Icons.search_off_rounded
                    : Icons.library_music_rounded,
                size: 42,
                color: const Color(0xFF7255B5),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              hasSearch ? 'No tunes found' : 'Your song shelf is waiting!',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              hasSearch
                  ? 'Try a different song or artist name.'
                  : 'Add some of your favorite music to get started.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: hasSearch ? onClearSearch : onImport,
              icon: Icon(hasSearch ? Icons.clear_rounded : Icons.add_rounded),
              label: Text(hasSearch ? 'Clear search' : 'Import songs'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _handleLibrarySongAction(
  BuildContext context,
  MusicPlayerModel model,
  Song song,
  String action,
) async {
  if (action == 'favorite') {
    try {
      await model.toggleFavorite(song);
    } catch (error) {
      if (context.mounted) {
        _showLibraryMessage(context, 'Unable to update favorite: $error');
      }
    }
    return;
  }

  if (action == 'playlist') {
    final playlists = model.playlists
        .where((playlist) => playlist.name != 'Favorites')
        .toList();
    final selected = await showDialog<Playlist>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add to playlist'),
        content: playlists.isEmpty
            ? const Text(
                'Create a playlist first to keep this song in a collection.',
              )
            : SizedBox(
                width: double.maxFinite,
                height: 280,
                child: ListView(
                  shrinkWrap: true,
                  children: playlists
                      .map(
                        (playlist) => ListTile(
                          leading: const Icon(Icons.queue_music_rounded),
                          title: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.pop(dialogContext, playlist),
                        ),
                      )
                      .toList(),
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (selected != null) {
      try {
        await model.addSongToPlaylist(song, selected);
      } catch (error) {
        if (context.mounted) {
          _showLibraryMessage(
            context,
            'Unable to add song to playlist: $error',
          );
        }
      }
    }
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Remove song from library?'),
      content: Text(
        '“${_songDisplayTitle(song)}” will be removed from your Tiny Tunes library and playlists. The audio file will not be deleted.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Remove song'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    await model.removeSong(song);
  } catch (error) {
    if (context.mounted) {
      _showLibraryMessage(context, 'Unable to remove song: $error');
    }
  }
}

String _songDisplayTitle(Song song) {
  final title = song.title.trim();
  if (title.isNotEmpty && title != 'Untitled track') return title;
  final filename = p
      .basenameWithoutExtension(song.filePath)
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .trim();
  return filename.isEmpty ? 'Untitled track' : filename;
}

void _showLibraryMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class PlaylistTab extends StatelessWidget {
  const PlaylistTab({required this.model, super.key});

  final MusicPlayerModel model;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: model.playlists.length,
      itemBuilder: (context, index) {
        final playlist = model.playlists[index];
        return FutureBuilder<List<Song>>(
          future: model.songsForPlaylist(playlist),
          builder: (context, snapshot) {
            final total = snapshot.data?.length ?? 0;
            return Card(
              child: ListTile(
                title: Text(playlist.name),
                subtitle: Text('$total song${total == 1 ? '' : 's'}'),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'rename') {
                      final controller = TextEditingController(
                        text: playlist.name,
                      );
                      final result = await showDialog<String>(
                        context: context,
                        builder: (dialogContext) {
                          return AlertDialog(
                            title: const Text('Rename playlist'),
                            content: TextField(controller: controller),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialogContext),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(
                                  dialogContext,
                                  controller.text,
                                ),
                                child: const Text('Save'),
                              ),
                            ],
                          );
                        },
                      );
                      if (result != null && result.trim().isNotEmpty) {
                        await model.renamePlaylist(playlist, result.trim());
                      }
                    }
                    if (value == 'delete') {
                      await model.deletePlaylist(playlist);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () async {
                  final songs = await model.songsForPlaylist(playlist);
                  if (!context.mounted) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlaylistDetailPage(
                        playlist: playlist,
                        songs: songs,
                        model: model,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage({
    required this.playlist,
    required this.songs,
    required this.model,
    super.key,
  });

  final Playlist playlist;
  final List<Song> songs;
  final MusicPlayerModel model;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: songs.isEmpty
          ? const Center(
              child: Text(
                'This playlist is empty. Add songs from the library.',
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                return ListTile(
                  leading: CircleAvatar(child: Text(song.leadingLetter)),
                  title: Text(song.title),
                  subtitle: Text(song.artist),
                  trailing: IconButton(
                    onPressed: () =>
                        model.removeSongFromPlaylist(song, playlist),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  onTap: () => model.playQueue(songs, startIndex: index),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (songs.isNotEmpty) {
            model.playQueue(songs, startIndex: 0);
          }
        },
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('Play playlist'),
      ),
    );
  }
}

class FavoritesTab extends StatelessWidget {
  const FavoritesTab({required this.model, super.key});

  final MusicPlayerModel model;

  @override
  Widget build(BuildContext context) {
    final favoriteSongs = model.favorites;

    return favoriteSongs.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No favorites yet. Tap the heart on a song to save it here.',
              ),
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: favoriteSongs.length,
            itemBuilder: (context, index) {
              final song = favoriteSongs[index];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.pink.shade100,
                    child: Text(song.leadingLetter),
                  ),
                  title: Text(song.title),
                  subtitle: Text('${song.artist} • ${song.durationLabel}'),
                  trailing: IconButton(
                    onPressed: () => model.toggleFavorite(song),
                    icon: const Icon(Icons.favorite, color: Colors.pink),
                  ),
                  onTap: () => model.playSong(song),
                ),
              );
            },
          );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({required this.model, super.key});

  final MusicPlayerModel model;

  @override
  Widget build(BuildContext context) {
    final song = model.currentSong;
    if (song == null) return const SizedBox.shrink();

    final maxValue = (model.duration?.inSeconds ?? 1).toDouble();
    final currentValue = model.position.inSeconds
        .clamp(0, maxValue.toInt())
        .toDouble();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        children: [
          Slider(
            value: currentValue,
            max: maxValue == 0 ? 1 : maxValue,
            onChanged: (value) =>
                model.seekTo(Duration(seconds: value.toInt())),
          ),
          Row(
            children: [
              CircleAvatar(child: Text(song.leadingLetter)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(song.artist, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => model.previousTrack(),
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                onPressed: () => model.togglePlayPause(),
                icon: Icon(model.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                onPressed: () => model.nextTrack(),
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.color,
  });

  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(Icons.music_note, color: color, size: 18),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
          ),
          Text(title),
        ],
      ),
    );
  }
}
