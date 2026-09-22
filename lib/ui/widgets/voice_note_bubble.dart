import 'dart:async';
import 'dart:io' show Platform, File, Directory;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../models/chat_message.dart';
import '../../services/voice_note_service.dart';
import '../../services/voice_note_playback_coordinator.dart';

class VoiceNoteBubble extends StatefulWidget {
  final ChatMessage msg;
  final VoiceNotePayload payload;
  final bool isMine;
  final bool isDark;
  final bool isConsecutive;
  final String timeStr;
  final Widget? statusIcon;
  final VoidCallback? onRetry;

  const VoiceNoteBubble({
    super.key,
    required this.msg,
    required this.payload,
    required this.isMine,
    required this.isDark,
    required this.isConsecutive,
    required this.timeStr,
    this.statusIcon,
    this.onRetry,
  });

  @override
  State<VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends State<VoiceNoteBubble>
    with AutomaticKeepAliveClientMixin
    implements VoiceNotePlaybackClient {
  final AudioPlayer _player = AudioPlayer();
  bool _isLoading = false;
  bool _isPlaying = false;
  bool _playOnReady = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _localFilePath;
  bool _hasError = false;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<void>? _completeSub;

  @override
  bool get wantKeepAlive => _isPlaying || _position > Duration.zero;

  @override
  void initState() {
    super.initState();
    _duration = Duration(milliseconds: widget.payload.durationMs);

    _resolveLocalFilePath();

    // Auto-fetch incoming or missing voice note in background
    if (_localFilePath == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startAutoDownload();
      });
    }

    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        final playing = state == PlayerState.playing;
        if (_isPlaying != playing) {
          setState(() {
            _isPlaying = playing;
          });
          updateKeepAlive();
        }
      }
    });

    _positionSub = _player.onPositionChanged.listen((pos) {
      if (mounted) {
        setState(() {
          _position = pos;
        });
      }
    });

    _durationSub = _player.onDurationChanged.listen((dur) {
      if (mounted && dur > Duration.zero) {
        if (_duration == Duration.zero || (_duration.inMilliseconds - dur.inMilliseconds).abs() > 1500) {
          setState(() {
            _duration = dur;
          });
        }
      }
    });

    _completeSub = _player.onPlayerComplete.listen((_) {
      VoiceNotePlaybackCoordinator.instance.stopIfActive(this);
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
        updateKeepAlive();
      }
    });
  }

  /// Pauses playback and immediately updates the UI icon to show the play/resume arrow.
  @override
  Future<void> pausePlayback() async {
    try {
      if (_isPlaying || _player.state == PlayerState.playing) {
        await _player.pause().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            debugPrint('DEBUG: _player.pause() timed out');
          },
        );
      }
    } catch (e) {
      debugPrint('DEBUG: Voice note pause error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
        updateKeepAlive();
      }
    }
  }

  void _resolveLocalFilePath() {
    // 1. Check direct payload localPath
    if (widget.payload.localPath != null && widget.payload.localPath!.isNotEmpty) {
      try {
        final localFile = File(widget.payload.localPath!);
        if (localFile.existsSync() && localFile.lengthSync() > 0) {
          _localFilePath = widget.payload.localPath;
          return;
        }
      } catch (_) {}
    }

    // 2. Check decrypted cached path in temporary directories
    if (widget.payload.fileHash.isNotEmpty) {
      final searchDirs = <String>[];
      if (VoiceNoteService.cachedTempDirPath != null) {
        searchDirs.add(VoiceNoteService.cachedTempDirPath!);
      }
      try {
        searchDirs.add(Directory.systemTemp.path);
      } catch (_) {}

      for (final dir in searchDirs) {
        try {
          final m4aCandidate = p.normalize(p.join(dir, 'vn_dec_${widget.payload.fileHash}.m4a'));
          if (File(m4aCandidate).existsSync() && File(m4aCandidate).lengthSync() > 0) {
            _localFilePath = m4aCandidate;
            return;
          }
          final wavCandidate = p.normalize(p.join(dir, 'vn_dec_${widget.payload.fileHash}.wav'));
          if (File(wavCandidate).existsSync() && File(wavCandidate).lengthSync() > 0) {
            _localFilePath = wavCandidate;
            return;
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _startAutoDownload() async {
    if (_localFilePath != null || _isLoading) return;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    final path = await VoiceNoteService().downloadAndDecryptVoiceNote(widget.payload);
    if (!mounted) return;

    if (path != null) {
      setState(() {
        _localFilePath = path;
        _isLoading = false;
      });
      if (_playOnReady) {
        _playOnReady = false;
        try {
          await VoiceNotePlaybackCoordinator.instance.requestPlayback(this);
          final cleanPath = p.normalize(path);
          await _player.setVolume(1.0);
          try {
            await _player.play(DeviceFileSource(cleanPath));
          } catch (_) {
            final bytes = await File(cleanPath).readAsBytes();
            await _player.play(BytesSource(bytes));
          }
          if (mounted) {
            setState(() {
              _isPlaying = true;
            });
            updateKeepAlive();
          }
        } catch (_) {
          VoiceNotePlaybackCoordinator.instance.stopIfActive(this);
        }
      }
    } else {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  @override
  void didUpdateWidget(VoiceNoteBubble oldWidget) {
    super.didUpdateWidget(oldWidget);

    final isDifferentVoice = widget.payload.fileHash != oldWidget.payload.fileHash ||
        widget.payload.localPath != oldWidget.payload.localPath ||
        widget.msg.timestamp != oldWidget.msg.timestamp;

    if (isDifferentVoice) {
      VoiceNotePlaybackCoordinator.instance.stopIfActive(this);
      _player.stop();
      setState(() {
        _isPlaying = false;
        _position = Duration.zero;
        _duration = Duration(milliseconds: widget.payload.durationMs);
        _localFilePath = null;
        _hasError = false;
        _isLoading = false;
      });
      updateKeepAlive();
      _resolveLocalFilePath();
      if (_localFilePath == null && !widget.isMine) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _startAutoDownload();
        });
      }
    } else {
      if (widget.payload.durationMs != oldWidget.payload.durationMs) {
        setState(() {
          _duration = Duration(milliseconds: widget.payload.durationMs);
        });
      }
      if (_localFilePath == null) {
        _resolveLocalFilePath();
      }
    }
  }

  @override
  void dispose() {
    VoiceNotePlaybackCoordinator.instance.stopIfActive(this);
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    // If message failed to send and audio is missing, retry send
    if (_hasError || (widget.msg.status == MessageStatus.failed && _localFilePath == null)) {
      if (widget.isMine) {
        widget.onRetry?.call();
      } else {
        _startAutoDownload();
      }
      return;
    }

    // If incoming message is still downloading, queue play on ready
    if (!widget.isMine && _isLoading) {
      _playOnReady = true;
      return;
    }

    // If local file is missing, resolve or download
    if (_localFilePath == null) {
      _resolveLocalFilePath();
      if (_localFilePath == null) {
        _playOnReady = true;
        _startAutoDownload();
        return;
      }
    }

    // Tapping while already playing pauses this voice note cleanly
    if (_isPlaying) {
      VoiceNotePlaybackCoordinator.instance.stopIfActive(this);
      await pausePlayback();
      return;
    }

    // Request central playback coordinator to cleanly pause any other voice note
    await VoiceNotePlaybackCoordinator.instance.requestPlayback(this);

    try {
      if (_position >= _duration && _duration > Duration.zero) {
        await _player.seek(Duration.zero);
        if (mounted) {
          setState(() {
            _position = Duration.zero;
          });
        }
      }

      final cleanPath = p.normalize(_localFilePath!);
      await _player.setVolume(1.0);

      // If player is already loaded and paused, resume smoothly from where it left off
      if (_player.state == PlayerState.paused) {
        try {
          await _player.resume();
          if (mounted) {
            setState(() {
              _isPlaying = true;
            });
            updateKeepAlive();
          }
          return;
        } catch (resumeErr) {
          debugPrint('DEBUG: _player.resume failed ($resumeErr), reloading source');
        }
      }

      final startPos = (_position > Duration.zero && _position < _duration) ? _position : null;
      try {
        await _player.play(
          DeviceFileSource(cleanPath),
          position: startPos,
        );
      } catch (devErr) {
        debugPrint('DEBUG: DeviceFileSource failed on desktop ($devErr), falling back to BytesSource');
        final bytes = await File(cleanPath).readAsBytes();
        await _player.play(
          BytesSource(bytes),
          position: startPos,
        );
      }

      if (mounted) {
        setState(() {
          _isPlaying = true;
        });
        updateKeepAlive();
      }
    } catch (e) {
      debugPrint('DEBUG: Voice note playback error: $e');
      VoiceNotePlaybackCoordinator.instance.stopIfActive(this);
      if (mounted) {
        setState(() {
          _hasError = true;
          _isPlaying = false;
        });
        updateKeepAlive();
      }
    }
  }

  void _seekToFraction(double fraction) {
    if (_duration == Duration.zero) return;
    final clampedFraction = fraction.clamp(0.0, 1.0);
    final targetMs = (_duration.inMilliseconds * clampedFraction).round();
    final target = Duration(milliseconds: targetMs);
    setState(() {
      _position = target;
    });
    updateKeepAlive();
    _player.seek(target);
  }

  String _formatDuration(Duration d, {bool isTotalDuration = false}) {
    int totalSeconds = d.inSeconds;
    if (isTotalDuration && totalSeconds == 0 && d.inMilliseconds >= 400) {
      totalSeconds = 1;
    }
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isMine = widget.isMine;
    final isDark = widget.isDark;

    // Theme bubble colors
    final bubbleColor = isMine
        ? (isDark ? const Color(0xFF2B5278) : const Color(0xFFDDF3FF))
        : (isDark ? const Color(0xFF1E1E1E) : Colors.white);

    final timeColor = isMine
        ? (isDark ? Colors.white.withValues(alpha: 0.65) : const Color(0xFF4A6572))
        : (isDark ? Colors.white.withValues(alpha: 0.5) : const Color(0xFF8E959B));

    final activeWaveformColor = isMine
        ? (isDark ? const Color(0xFF64B5F6) : const Color(0xFF0284C7))
        : (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7));

    final inactiveWaveformColor = isMine
        ? (isDark ? Colors.white30 : const Color(0xFF94A3B8).withValues(alpha: 0.6))
        : (isDark ? const Color(0xFF52525B) : const Color(0xFFCBD5E1));

    final playBtnColor = isMine
        ? (isDark ? const Color(0xFF64B5F6) : const Color(0xFF0284C7))
        : (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7));

    final borderRadius = BorderRadius.only(
      topLeft: Radius.circular(!isMine && !widget.isConsecutive ? 2 : 12),
      topRight: Radius.circular(isMine && !widget.isConsecutive ? 2 : 12),
      bottomLeft: const Radius.circular(12),
      bottomRight: const Radius.circular(12),
    );

    // Calculate progress fraction
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final displayDurationStr = (_isPlaying || _position > Duration.zero)
        ? _formatDuration(_position)
        : _formatDuration(_duration, isTotalDuration: true);

    final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final bubbleWidth = isDesktop ? 250.0 : (MediaQuery.sizeOf(context).width * 0.65).clamp(205.0, 230.0);

    final isSending = widget.msg.status == MessageStatus.sending;
    final isFailed = widget.msg.status == MessageStatus.failed;
    final isIncomingLoading = !widget.isMine && (_isLoading || (_localFilePath == null && !_hasError));
    final showPlaySpinner = isIncomingLoading || (isSending && _localFilePath == null);
    final isActionableError = (isFailed && _localFilePath == null) || _hasError;
    final buttonColor = isActionableError ? const Color(0xFFEF4444) : playBtnColor;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: bubbleWidth,
          minWidth: 200.0,
        ),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: showPlaySpinner ? 0.82 : 1.0,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 2.0),
            padding: const EdgeInsets.fromLTRB(8, 6, 10, 4),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: borderRadius,
              border: !isMine
                  ? Border.all(
                      color: isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE4E4E7),
                      width: 1,
                    )
                  : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Compact 34x34 Play/Pause/Download/Sending button
                    GestureDetector(
                      onTap: (showPlaySpinner && !isActionableError) ? null : _togglePlayback,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: buttonColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: buttonColor.withValues(alpha: 0.25),
                              blurRadius: 4,
                              offset: const Offset(0, 1.5),
                            ),
                          ],
                        ),
                        child: Center(
                          child: showPlaySpinner
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  isActionableError
                                      ? Icons.refresh_rounded
                                      : (_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                  color: Colors.white,
                                  size: 21,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Seekable Waveform Bar (height 24px)
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: showPlaySpinner
                                ? null
                                : (details) {
                                    final fraction = details.localPosition.dx / constraints.maxWidth;
                                    _seekToFraction(fraction);
                                  },
                            onHorizontalDragUpdate: showPlaySpinner
                                ? null
                                : (details) {
                                    final fraction = details.localPosition.dx / constraints.maxWidth;
                                    _seekToFraction(fraction);
                                  },
                            child: SizedBox(
                              height: 24,
                              child: CustomPaint(
                                painter: _WaveformPainter(
                                  waveform: widget.payload.waveform,
                                  progress: progress,
                                  activeColor: activeWaveformColor,
                                  inactiveColor: inactiveWaveformColor,
                                ),
                                size: Size(constraints.maxWidth, 24),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),

                // Bottom row: Duration on left, Time & Status on right
                Padding(
                  padding: const EdgeInsets.only(left: 42.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        displayDurationStr,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: timeColor,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.timeStr,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: timeColor,
                            ),
                          ),
                          if (isMine && widget.statusIcon != null) ...[
                            const SizedBox(width: 3.0),
                            widget.statusIcon!,
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<int> waveform;
  final double progress; // 0.0 to 1.0
  final Color activeColor;
  final Color inactiveColor;

  _WaveformPainter({
    required this.waveform,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (waveform.isEmpty) {
      // Draw placeholder bars if waveform is empty
      final paint = Paint()
        ..color = inactiveColor
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.0;
      for (double x = 4; x < size.width - 4; x += 5) {
        canvas.drawLine(
          Offset(x, size.height / 2 - 3),
          Offset(x, size.height / 2 + 3),
          paint,
        );
      }
      return;
    }

    final barCount = waveform.length;
    final totalSpacing = size.width;
    final barWidth = (totalSpacing / (barCount * 1.5)).clamp(1.8, 2.8);
    final gap = (size.width - (barCount * barWidth)) / (barCount > 1 ? barCount - 1 : 1);

    final activePaint = Paint()
      ..color = activeColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    final progressX = progress * size.width;
    final centerY = size.height / 2;
    final maxHeight = size.height - 2;

    for (int i = 0; i < barCount; i++) {
      final x = i * (barWidth + gap) + (barWidth / 2);
      final amplitude = (waveform[i] / 100.0).clamp(0.08, 1.0);
      final barHalfHeight = (maxHeight / 2) * amplitude;

      final isPast = x <= progressX;
      final paint = isPast ? activePaint : inactivePaint;

      canvas.drawLine(
        Offset(x, centerY - barHalfHeight),
        Offset(x, centerY + barHalfHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.waveform != waveform;
  }
}
