import 'package:flutter/foundation.dart';

/// Contract for any audio client (e.g. voice note bubble) managed by the coordinator.
abstract class VoiceNotePlaybackClient {
  /// Pauses the audio player and updates UI state to non-playing (showing play/resume icon).
  Future<void> pausePlayback();
}

/// Global coordinator ensuring only ONE voice note plays across the application at any time.
/// When a voice note requests playback, any currently active voice note is cleanly paused,
/// its player stream halted, and its UI updated so its icon reflects the paused state.
class VoiceNotePlaybackCoordinator {
  VoiceNotePlaybackCoordinator._();
  static final VoiceNotePlaybackCoordinator instance = VoiceNotePlaybackCoordinator._();

  VoiceNotePlaybackClient? _activeClient;

  /// Returns the currently active playing client, if any.
  VoiceNotePlaybackClient? get activeClient => _activeClient;

  /// Requests playback for [client]. Any previously playing client will be paused cleanly.
  Future<void> requestPlayback(VoiceNotePlaybackClient client) async {
    final prev = _activeClient;
    _activeClient = client;
    if (prev != null && prev != client) {
      try {
        await prev.pausePlayback();
      } catch (e) {
        debugPrint('VoiceNotePlaybackCoordinator: error pausing previous voice note: $e');
      }
    }
  }

  /// Informs the coordinator that [client] has paused, completed, or been disposed.
  void stopIfActive(VoiceNotePlaybackClient client) {
    if (_activeClient == client) {
      _activeClient = null;
    }
  }

  /// Pauses any currently playing voice note across the entire app.
  Future<void> stopAll() async {
    final prev = _activeClient;
    _activeClient = null;
    if (prev != null) {
      try {
        await prev.pausePlayback();
      } catch (e) {
        debugPrint('VoiceNotePlaybackCoordinator: error in stopAll: $e');
      }
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _activeClient = null;
  }
}
