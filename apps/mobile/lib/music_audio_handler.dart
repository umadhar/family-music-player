import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  MusicAudioHandler(this.player) {
    _subscriptions.add(
      player.playbackEventStream.listen(
        (_) => _publishPlaybackState(),
        onError: (Object error, StackTrace stackTrace) {
          _publishError(error);
        },
      ),
    );
    _subscriptions.add(
      player.currentIndexStream.listen((index) {
        if (index != null && index >= 0 && index < _items.length) {
          mediaItem.add(_items[index]);
        }
      }),
    );
    _subscriptions.add(
      player.durationStream.listen((duration) {
        final current = mediaItem.value;
        if (duration == null || current == null) return;

        final updated = current.copyWith(duration: duration);
        final index = _items.indexWhere((item) => item.id == current.id);
        if (index >= 0) {
          _items[index] = updated;
          queue.add(List.unmodifiable(_items));
        }
        mediaItem.add(updated);
      }),
    );
    _subscriptions.add(player.errorStream.listen(_publishError));
  }

  final AudioPlayer player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<MediaItem> _items = [];

  Stream<Duration> get positionStream => player.positionStream;
  Stream<Duration?> get durationStream => player.durationStream;
  MediaItem? get currentMediaItem => mediaItem.value;
  Duration get position => player.position;
  Duration? get duration => player.duration;
  bool get shuffleEnabled => player.shuffleModeEnabled;
  bool get repeatEnabled => player.loopMode == LoopMode.all;

  Future<void> setQueue(
    List<MediaItem> items, {
    int startIndex = 0,
    bool shuffleEnabled = false,
    bool repeatEnabled = false,
  }) async {
    final nextItems = List<MediaItem>.of(items);
    if (nextItems.isEmpty) {
      Object? clearError;
      StackTrace? clearStackTrace;
      try {
        await player.stop();
      } catch (error, stackTrace) {
        clearError = error;
        clearStackTrace = stackTrace;
      }
      try {
        await player.setAudioSources(const [], preload: false);
      } catch (error, stackTrace) {
        clearError ??= error;
        clearStackTrace ??= stackTrace;
      }
      _items = [];
      queue.add(const []);
      mediaItem.add(null);
      await super.stop();
      if (clearError != null) {
        Error.throwWithStackTrace(clearError, clearStackTrace!);
      }
      return;
    }

    final safeIndex = startIndex.clamp(0, nextItems.length - 1);
    final sources = nextItems
        .map((item) {
          final filePath = item.extras?['filePath'];
          if (filePath is! String || filePath.isEmpty) {
            throw ArgumentError.value(
              item.id,
              'item.id',
              'A local file path is required for each queue item.',
            );
          }
          return AudioSource.uri(Uri.file(filePath), tag: item);
        })
        .toList(growable: false);

    await player.setAudioSources(
      sources,
      initialIndex: safeIndex,
      preload: false,
    );
    _items = nextItems;
    queue.add(List.unmodifiable(_items));
    await setRepeatMode(
      repeatEnabled ? AudioServiceRepeatMode.all : AudioServiceRepeatMode.none,
    );
    await setShuffleMode(
      shuffleEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
    mediaItem.add(_items[safeIndex]);
  }

  Future<void> removeFromQueue(String itemId) async {
    final removedIndex = _items.indexWhere((item) => item.id == itemId);
    if (removedIndex < 0) return;

    final currentId = mediaItem.value?.id;
    final currentIndex = currentId == null
        ? player.currentIndex
        : _items.indexWhere((item) => item.id == currentId);
    final wasPlaying = player.playing;
    final remainingItems = List<MediaItem>.of(_items)..removeAt(removedIndex);

    if (remainingItems.isEmpty) {
      await setQueue([]);
      return;
    }

    final nextIndex = currentId == itemId || currentIndex == removedIndex
        ? removedIndex.clamp(0, remainingItems.length - 1)
        : remainingItems.indexWhere((item) => item.id == currentId);
    try {
      await setQueue(
        remainingItems,
        startIndex: nextIndex < 0 ? 0 : nextIndex,
        shuffleEnabled: shuffleEnabled,
        repeatEnabled: repeatEnabled,
      );
    } catch (error, stackTrace) {
      try {
        await setQueue([]);
      } catch (clearError) {
        throw StateError(
          'Unable to update the playback queue: $error. '
          'Clearing the queue also failed: $clearError.',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (wasPlaying) await play();
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) => setQueue(
    queue,
    startIndex: 0,
    shuffleEnabled: shuffleEnabled,
    repeatEnabled: repeatEnabled,
  );

  @override
  Future<void> play() async {
    if (_items.isEmpty) return;
    if (player.processingState == ProcessingState.completed) {
      final index = player.currentIndex;
      if (index != null) await player.seek(Duration.zero, index: index);
    }
    await player.play();
  }

  @override
  Future<void> pause() async {
    if (_items.isNotEmpty) await player.pause();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_items.isNotEmpty) await player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (_items.isEmpty) return;

    if (player.hasNext) {
      await player.seekToNext();
    } else {
      final index = player.currentIndex;
      if (index != null) await player.seek(Duration.zero, index: index);
    }
    await play();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_items.isEmpty) return;

    if (player.hasPrevious) {
      await player.seekToPrevious();
    } else {
      final index = player.currentIndex;
      if (index != null) await player.seek(Duration.zero, index: index);
    }
    await play();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _items.length) return;
    await player.seek(Duration.zero, index: index);
    await play();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await player.setShuffleModeEnabled(
      shuffleMode != AudioServiceShuffleMode.none,
    );
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await player.setLoopMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => LoopMode.all,
      AudioServiceRepeatMode.none => LoopMode.off,
    });
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  Future<void> dispose() async {
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    await player.dispose();
    await playbackState.close();
    await queue.close();
    await queueTitle.close();
    await mediaItem.close();
    await androidPlaybackInfo.close();
    await ratingStyle.close();
    await customEvent.close();
    await customState.close();
  }

  void _publishPlaybackState() {
    if (player.processingState == ProcessingState.completed && player.playing) {
      unawaited(
        player.pause().catchError((Object error) {
          _publishError(error);
        }),
      );
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          player.playing && player.processingState != ProcessingState.completed
              ? MediaControl.pause
              : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing:
            player.playing &&
            player.processingState != ProcessingState.completed,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: player.currentIndex,
        shuffleMode: shuffleEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: repeatEnabled
            ? AudioServiceRepeatMode.all
            : AudioServiceRepeatMode.none,
      ),
    );
  }

  void _publishError(Object error) {
    final message = error is PlayerException ? error.message : error.toString();
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        playing: false,
        controls: const [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.skipToNext,
        ],
        errorMessage: message,
      ),
    );
  }
}
