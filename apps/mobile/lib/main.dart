import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(const KidsMusicPlayerApp());
}

class KidsMusicPlayerApp extends StatelessWidget {
  const KidsMusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MusicPlayerModel()..initialize(),
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

class Playlist {
  const Playlist({required this.id, required this.name});

  final int id;
  final String name;

  factory Playlist.fromMap(Map<String, dynamic> map) {
    return Playlist(id: map['id'] as int, name: map['name'] as String);
  }
}

class MusicLibraryRepository {
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
        .basenameWithoutExtension(destinationFile.path)
        .replaceAll('_', ' ');
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
  MusicPlayerModel()
    : _repository = MusicLibraryRepository(),
      _player = AudioPlayer();

  final MusicLibraryRepository _repository;
  final AudioPlayer _player;

  final List<Song> _songs = [];
  final List<Playlist> _playlists = [];
  final List<Song> _queue = [];
  String _searchTerm = '';
  Song? _currentSong;
  int _currentQueueIndex = -1;
  bool _isReady = false;
  bool _isPlaying = false;
  bool _shuffleEnabled = false;
  bool _repeatEnabled = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  String? _statusMessage;

  bool get isReady => _isReady;
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

  Song? get currentSong => _currentSong;
  bool get isPlaying => _isPlaying;
  bool get shuffleEnabled => _shuffleEnabled;
  bool get repeatEnabled => _repeatEnabled;
  Duration get position => _position;
  Duration? get duration => _duration;
  String? get statusMessage => _statusMessage;

  Future<void> initialize() async {
    await _repository.initialize();
    await refresh();

    _player.playerStateStream.listen((state) {
      final isPlaying = state.playing;
      if (_isPlaying != isPlaying) {
        _isPlaying = isPlaying;
        notifyListeners();
      }
    });

    _player.positionStream.listen((value) {
      _position = value;
      notifyListeners();
    });

    _player.durationStream.listen((value) {
      _duration = value;
      if (value != null && _currentSong != null) {
        final durationMs = value.inMilliseconds;
        if (durationMs > 0) {
          _repository.updateDuration(_currentSong!.id, durationMs);
          final index = _songs.indexWhere(
            (element) => element.id == _currentSong!.id,
          );
          if (index >= 0) {
            _songs[index] = Song(
              id: _songs[index].id,
              title: _songs[index].title,
              artist: _songs[index].artist,
              filePath: _songs[index].filePath,
              durationMs: durationMs,
              isFavorite: _songs[index].isFavorite,
            );
          }
        }
      }
      notifyListeners();
    });

    _isReady = true;
    notifyListeners();
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

    final safeIndex = startIndex.clamp(0, songs.length - 1);
    _queue
      ..clear()
      ..addAll(songs);
    _currentQueueIndex = safeIndex;
    _currentSong = songs[safeIndex];

    final audioSources = songs
        .map((song) => AudioSource.uri(Uri.file(song.filePath)))
        .toList(growable: false);

    try {
      await _player.setAudioSources(
        audioSources,
        initialIndex: safeIndex,
        preload: false,
      );
      await _player.play();
      _isPlaying = true;
      _statusMessage = 'Now playing ${_currentSong!.title}';
      notifyListeners();
    } catch (_) {
      _statusMessage =
          'Unable to play ${_currentSong!.title}. The file may be missing.';
      notifyListeners();
    }
  }

  Future<void> playSong(Song song) async {
    final queue = filteredSongs.isNotEmpty ? filteredSongs : songs;
    final index = queue.indexWhere((entry) => entry.id == song.id);
    await playQueue(queue, startIndex: index >= 0 ? index : 0);
  }

  Future<void> togglePlayPause() async {
    if (_currentSong == null) {
      if (_songs.isNotEmpty) {
        await playQueue(_songs, startIndex: 0);
      }
      return;
    }

    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    notifyListeners();
  }

  Future<void> nextTrack() async {
    if (_queue.isEmpty) {
      if (_songs.isNotEmpty) {
        await playQueue(_songs, startIndex: 0);
      }
      return;
    }

    int nextIndex = _currentQueueIndex + 1;
    if (_shuffleEnabled) {
      nextIndex = _randomIndex();
    } else if (nextIndex >= _queue.length) {
      if (_repeatEnabled) {
        nextIndex = 0;
      } else {
        nextIndex = _queue.length - 1;
      }
    }

    _currentQueueIndex = nextIndex;
    _currentSong = _queue[nextIndex];
    await _player.seek(Duration.zero, index: nextIndex);
    await _player.play();
    notifyListeners();
  }

  Future<void> previousTrack() async {
    if (_queue.isEmpty) return;

    var previousIndex = _currentQueueIndex - 1;
    if (previousIndex < 0) {
      previousIndex = _repeatEnabled ? _queue.length - 1 : 0;
    }

    _currentQueueIndex = previousIndex;
    _currentSong = _queue[previousIndex];
    await _player.seek(Duration.zero, index: previousIndex);
    await _player.play();
    notifyListeners();
  }

  int _randomIndex() {
    if (_queue.length < 2) return 0;
    final random = DateTime.now().millisecondsSinceEpoch % _queue.length;
    return random;
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
      if (_currentSong != null && _currentSong!.id == song.id) {
        _currentSong = updatedSong;
      }
    }
    notifyListeners();
  }

  Future<void> seekTo(Duration value) async {
    await _player.seek(value);
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
    _shuffleEnabled = !_shuffleEnabled;
    notifyListeners();
  }

  Future<void> toggleRepeat() async {
    _repeatEnabled = !_repeatEnabled;
    notifyListeners();
  }

  Future<List<Song>> songsForPlaylist(Playlist playlist) async {
    return _repository.getSongsForPlaylist(playlist.id);
  }

  Future<void> disposePlayer() async {
    await _player.dispose();
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            onChanged: model.setSearchTerm,
            decoration: InputDecoration(
              hintText: 'Search songs or artists',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
        if (model.statusMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              model.statusMessage!,
              style: const TextStyle(color: Colors.green),
            ),
          ),
        Expanded(
          child: songs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No songs match your search yet. Try importing a few tracks.',
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: songs.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.deepPurple.shade100,
                          child: Text(song.leadingLetter),
                        ),
                        title: Text(song.title),
                        subtitle: Text(
                          '${song.artist} • ${song.durationLabel}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () => model.toggleFavorite(song),
                              icon: Icon(
                                song.isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: Colors.pink,
                              ),
                            ),
                            IconButton(
                              onPressed: () => model.playSong(song),
                              icon: const Icon(Icons.play_circle_outline),
                            ),
                          ],
                        ),
                        onTap: () => model.playSong(song),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
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
