import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/chat_message.dart';
import '../../models/media_payload.dart';
import '../../services/media_service.dart';
import '../../services/media_cache_manager.dart';
import 'media_preview_screen.dart';
import 'whatsapp_formatter.dart';

class MediaBubble extends StatefulWidget {
  final ChatMessage msg;
  final MediaPayload payload;
  final bool isMine;
  final bool isDark;
  final bool isConsecutive;
  final String timeStr;
  final Widget? statusIcon;
  final VoidCallback? onRetry;

  const MediaBubble({
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
  State<MediaBubble> createState() => _MediaBubbleState();
}

class _MediaBubbleState extends State<MediaBubble> {
  String? _localDecryptedPath;
  bool _isDownloading = false;
  bool _downloadFailed = false;
  bool _isPlayingInline = false;

  @override
  void initState() {
    super.initState();
    _resolveInitialLocalPath();
    _checkLocalOrStartDownload();
  }

  void _resolveInitialLocalPath() {
    if (widget.payload.localPath != null && widget.payload.localPath!.isNotEmpty) {
      try {
        final localFile = File(widget.payload.localPath!);
        if (localFile.existsSync() && localFile.lengthSync() > 0) {
          _localDecryptedPath = widget.payload.localPath;
          return;
        }
      } catch (_) {}
    }

    if (widget.payload.fileHash.isNotEmpty) {
      final cached = MediaCacheManager().getCachedFilePath(widget.payload.fileHash);
      if (cached != null) {
        try {
          final cachedFile = File(cached);
          if (cachedFile.existsSync() && cachedFile.lengthSync() > 0) {
            _localDecryptedPath = cached;
            return;
          }
        } catch (_) {}
      }
    }
  }

  @override
  void didUpdateWidget(MediaBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload.fileHash != widget.payload.fileHash ||
        oldWidget.payload.localPath != widget.payload.localPath) {
      _resolveInitialLocalPath();
      _checkLocalOrStartDownload();
    }
  }

  Future<void> _checkLocalOrStartDownload() async {
    if (_localDecryptedPath != null && File(_localDecryptedPath!).existsSync()) {
      return;
    }

    // Check async cache lookup
    if (widget.payload.fileHash.isNotEmpty) {
      final asyncCached = await MediaCacheManager().findCachedFilePath(widget.payload.fileHash);
      if (asyncCached != null && File(asyncCached).existsSync()) {
        if (mounted) {
          setState(() {
            _localDecryptedPath = asyncCached;
            _isDownloading = false;
            _downloadFailed = false;
          });
        }
        return;
      }
    }

    // For sender messages: sender has local file or if not found, don't show download spinner from blossom
    if (widget.isMine) {
      return;
    }

    // 3. For recipient: if image, automatically trigger download in background
    if (widget.payload.isImage) {
      _triggerDownload();
    }
  }

  Future<void> _triggerDownload() async {
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _downloadFailed = false;
    });

    try {
      final path = await MediaService().downloadAndDecryptMedia(widget.payload);
      if (mounted) {
        if (path != null && File(path).existsSync()) {
          setState(() {
            _localDecryptedPath = path;
            _isDownloading = false;
            _downloadFailed = false;
          });
        } else {
          setState(() {
            _isDownloading = false;
            _downloadFailed = true;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadFailed = true;
        });
      }
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final bubbleColor = widget.isMine
        ? const Color(0xFF2B5278)
        : (widget.isDark ? const Color(0xFF242424) : const Color(0xFFF4F4F5));

    final timeColor = widget.isMine
        ? Colors.white.withValues(alpha: 0.7)
        : (widget.isDark ? Colors.white54 : const Color(0xFF8E959B));

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(widget.isMine ? 16 : (widget.isConsecutive ? 4 : 0)),
      bottomRight: Radius.circular(widget.isMine ? (widget.isConsecutive ? 4 : 0) : 16),
    );

    return Align(
      alignment: widget.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          top: widget.isConsecutive ? 2 : 6,
          bottom: 2,
          left: widget.isMine ? 50 : 8,
          right: widget.isMine ? 8 : 50,
        ),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
            )
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.payload.isImage) _buildImageContent(),
              if (widget.payload.isVideo) _buildVideoContent(),
              if (widget.payload.isDocument || widget.payload.isAudio) _buildDocumentContent(),
              if (widget.payload.caption != null && widget.payload.caption!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                  child: WhatsAppFormattedText(
                    text: widget.payload.caption!,
                    baseStyle: TextStyle(
                      fontSize: 14.5,
                      height: 1.3,
                      color: widget.isMine ? Colors.white : (widget.isDark ? Colors.white : const Color(0xFF17202A)),
                    ),
                    isMine: widget.isMine,
                    isDark: widget.isDark,
                  ),
                ),
              // Metadata Row (Timestamp + Status Ticks)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Spacer(),
                    Text(
                      widget.timeStr,
                      style: TextStyle(
                        fontSize: 11,
                        color: timeColor,
                      ),
                    ),
                    if (widget.isMine && widget.statusIcon != null) ...[
                      const SizedBox(width: 4),
                      widget.statusIcon!,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageContent() {
    return GestureDetector(
      onTap: () {
        if (_localDecryptedPath != null && File(_localDecryptedPath!).existsSync()) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MediaPreviewScreen(
                filePath: _localDecryptedPath!,
                title: widget.payload.fileName.isNotEmpty ? widget.payload.fileName : 'Photo',
                mediaType: 'image',
              ),
            ),
          );
        } else if (!widget.isMine) {
          _triggerDownload();
        }
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Decrypted Full Image (if loaded)
          if (_localDecryptedPath != null && File(_localDecryptedPath!).existsSync())
            Image.file(
              File(_localDecryptedPath!),
              fit: BoxFit.cover,
              width: 320,
              height: 220,
            )
          // 2. Micro Blurred Thumbnail placeholder (instant preview)
          else if (widget.payload.thumbnail != null && widget.payload.thumbnail!.isNotEmpty)
            Image.memory(
              base64Decode(widget.payload.thumbnail!),
              fit: BoxFit.cover,
              width: 320,
              height: 220,
            )
          else
            Container(
              width: 320,
              height: 180,
              color: Colors.black12,
              child: const Icon(Icons.image_rounded, size: 48, color: Colors.white54),
            ),

          // 3. Download Progress or Tap to Download overlay (only for receiver when decrypted file is not ready)
          if ((_localDecryptedPath == null || !File(_localDecryptedPath!).existsSync()) && !widget.isMine)
            Container(
              width: 320,
              height: 220,
              color: Colors.black38,
              child: Center(
                child: _isDownloading
                    ? const SizedBox(
                        width: 38,
                        height: 38,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                      )
                    : IconButton(
                        icon: Icon(
                          _downloadFailed ? Icons.refresh_rounded : Icons.download_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                        onPressed: _triggerDownload,
                        tooltip: _downloadFailed ? 'Retry download' : 'Download image',
                      ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideoContent() {
    final hasLocalFile = _localDecryptedPath != null && File(_localDecryptedPath!).existsSync();

    if (_isPlayingInline && hasLocalFile) {
      return _InlineVideoBubblePlayer(
        filePath: _localDecryptedPath!,
        title: widget.payload.fileName.isNotEmpty ? widget.payload.fileName : 'Video',
        aspectRatio: (widget.payload.width != null &&
                widget.payload.height != null &&
                widget.payload.width! > 0 &&
                widget.payload.height! > 0)
            ? (widget.payload.width! / widget.payload.height!)
            : (16 / 9),
        onOpenFullscreen: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MediaPreviewScreen(
                filePath: _localDecryptedPath!,
                title: widget.payload.fileName.isNotEmpty ? widget.payload.fileName : 'Video',
                mediaType: 'video',
              ),
            ),
          );
        },
        onClose: () {
          setState(() {
            _isPlayingInline = false;
          });
        },
      );
    }

    return GestureDetector(
      onTap: () {
        if (hasLocalFile) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MediaPreviewScreen(
                filePath: _localDecryptedPath!,
                title: widget.payload.fileName.isNotEmpty ? widget.payload.fileName : 'Video',
                mediaType: 'video',
              ),
            ),
          );
        } else if (!widget.isMine) {
          _triggerDownload();
        }
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 320,
            height: 180,
            color: Colors.black26,
            child: widget.payload.thumbnail != null
                ? Image.memory(
                    base64Decode(widget.payload.thumbnail!),
                    fit: BoxFit.cover,
                  )
                : const Icon(Icons.videocam_rounded, size: 54, color: Colors.white60),
          ),
          // Play button (tap to play inline) or Download button
          GestureDetector(
            onTap: () {
              if (hasLocalFile) {
                setState(() {
                  _isPlayingInline = true;
                });
              } else if (!widget.isMine) {
                _triggerDownload();
              }
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: _isDownloading
                  ? const Padding(
                      padding: EdgeInsets.all(10.0),
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                    )
                  : Icon(
                      hasLocalFile || widget.isMine
                          ? Icons.play_arrow_rounded
                          : (_downloadFailed ? Icons.refresh_rounded : Icons.download_rounded),
                      color: Colors.white,
                      size: 30,
                    ),
            ),
          ),
          // Top-right Fullscreen shortcut icon (if file exists)
          if (hasLocalFile)
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MediaPreviewScreen(
                        filePath: _localDecryptedPath!,
                        title: widget.payload.fileName.isNotEmpty ? widget.payload.fileName : 'Video',
                        mediaType: 'video',
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 20),
                ),
              ),
            ),
          // Duration pill if available
          if (widget.payload.durationMs > 0)
            Positioned(
              bottom: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${widget.payload.durationMs ~/ 1000}s',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDocumentContent() {
    final ext = widget.payload.fileName.contains('.')
        ? widget.payload.fileName.split('.').last.toUpperCase()
        : (widget.payload.isAudio ? 'AUDIO' : 'DOC');

    final extColor = ext == 'PDF'
        ? Colors.redAccent
        : (['DOC', 'DOCX'].contains(ext)
            ? Colors.blueAccent
            : (['ZIP', 'RAR', '7Z'].contains(ext) ? Colors.orangeAccent : Colors.teal));

    return InkWell(
      onTap: () {
        if (_localDecryptedPath != null && File(_localDecryptedPath!).existsSync()) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MediaPreviewScreen(
                filePath: _localDecryptedPath!,
                title: widget.payload.fileName.isNotEmpty ? widget.payload.fileName : 'Document',
                mediaType: widget.payload.mediaType,
              ),
            ),
          );
        } else if (!widget.isMine) {
          _triggerDownload();
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            // Extension Tile
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: extColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  ext.length > 4 ? ext.substring(0, 4) : ext,
                  style: TextStyle(
                    color: extColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.payload.fileName.isNotEmpty ? widget.payload.fileName : 'Document',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: widget.isMine
                          ? Colors.white
                          : (widget.isDark ? Colors.white : const Color(0xFF17202A)),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatFileSize(widget.payload.fileSize),
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.isMine
                          ? Colors.white.withValues(alpha: 0.7)
                          : (widget.isDark ? Colors.white60 : Colors.black54),
                    ),
                  ),
                ],
              ),
            ),
            if (_isDownloading)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else if ((_localDecryptedPath == null || !File(_localDecryptedPath!).existsSync()) && !widget.isMine)
              IconButton(
                icon: Icon(
                  _downloadFailed ? Icons.refresh_rounded : Icons.download_rounded,
                  color: widget.isMine ? Colors.white : Colors.black87,
                ),
                onPressed: _triggerDownload,
              )
            else
              Icon(
                Icons.open_in_new_rounded,
                size: 20,
                color: widget.isMine
                    ? Colors.white.withValues(alpha: 0.7)
                    : Colors.black54,
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline video player embedded directly inside chat bubbles with video progress bar and mute button.
class _InlineVideoBubblePlayer extends StatefulWidget {
  final String filePath;
  final String title;
  final double aspectRatio;
  final VoidCallback onOpenFullscreen;
  final VoidCallback onClose;

  const _InlineVideoBubblePlayer({
    required this.filePath,
    required this.title,
    required this.aspectRatio,
    required this.onOpenFullscreen,
    required this.onClose,
  });

  @override
  State<_InlineVideoBubblePlayer> createState() => _InlineVideoBubblePlayerState();
}

class _InlineVideoBubblePlayerState extends State<_InlineVideoBubblePlayer> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _isMuted = false;
  bool _showControls = true;
  bool _isDragging = false;
  double _dragPosition = 0.0;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        if (mounted) {
          setState(() {
            _isInitialized = true;
          });
          _controller.play();
          _startHideTimer();
        }
      });
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controller.value.isPlaying && !_isDragging) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _togglePlayPause() {
    if (!_isInitialized) return;
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
        _showControls = true;
        _hideControlsTimer?.cancel();
      } else {
        if (_controller.value.position >= _controller.value.duration) {
          _controller.seekTo(Duration.zero);
        }
        _controller.play();
        _showControls = true;
        _startHideTimer();
      }
    });
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _controller.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Container(
        width: 320,
        height: 180,
        color: Colors.black,
        child: const Center(
          child: SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
          ),
        ),
      );
    }

    final isPlaying = _controller.value.isPlaying;
    final isFinished = _controller.value.position >= _controller.value.duration;
    final durationMs = _controller.value.duration.inMilliseconds.toDouble();
    final currentPosMs = _isDragging
        ? _dragPosition
        : _controller.value.position.inMilliseconds.toDouble();

    final actualRatio = _controller.value.aspectRatio > 0
        ? _controller.value.aspectRatio
        : widget.aspectRatio;

    return Container(
      width: 320,
      constraints: const BoxConstraints(maxHeight: 280),
      color: Colors.black,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            _showControls = !_showControls;
          });
          if (_showControls && isPlaying) {
            _startHideTimer();
          } else {
            _hideControlsTimer?.cancel();
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 1. Video Player
            AspectRatio(
              aspectRatio: actualRatio,
              child: VideoPlayer(_controller),
            ),

            // 2. Center Play / Pause / Replay icon
            if (_showControls || !isPlaying)
              Center(
                child: GestureDetector(
                  onTap: _togglePlayPause,
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white30, width: 1.5),
                    ),
                    child: Icon(
                      isFinished
                          ? Icons.replay_rounded
                          : (isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),

            // 3. Top Action Buttons (Fullscreen & Close Inline)
            if (_showControls)
              Positioned(
                top: 4,
                right: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.fullscreen_rounded, color: Colors.white, size: 24),
                      tooltip: 'Fullscreen',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () {
                        _controller.pause();
                        widget.onOpenFullscreen();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                      tooltip: 'Close inline',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),

            // 4. Bottom Controls: Scrubber, Play/Pause, Position, Mute Button!
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.85),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Video Progress Bar (Scrubber)
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3.0,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                            activeTrackColor: const Color(0xFF2B5278),
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            overlayColor: const Color(0xFF2B5278).withValues(alpha: 0.25),
                          ),
                          child: Slider(
                            value: currentPosMs.clamp(0.0, durationMs > 0 ? durationMs : 1.0),
                            min: 0.0,
                            max: durationMs > 0 ? durationMs : 1.0,
                            onChangeStart: (val) {
                              _hideControlsTimer?.cancel();
                              setState(() {
                                _isDragging = true;
                                _dragPosition = val;
                              });
                            },
                            onChanged: (val) {
                              setState(() {
                                _dragPosition = val;
                              });
                            },
                            onChangeEnd: (val) {
                              _controller.seekTo(Duration(milliseconds: val.toInt()));
                              setState(() {
                                _isDragging = false;
                              });
                              if (isPlaying) {
                                _startHideTimer();
                              }
                            },
                          ),
                        ),
                        // Bottom row: Play/Pause, Time, Mute
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              onPressed: _togglePlayPause,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${_formatDuration(Duration(milliseconds: currentPosMs.toInt()))} / ${_formatDuration(_controller.value.duration)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            // Mute button
                            IconButton(
                              icon: Icon(
                                _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                                color: _isMuted ? Colors.redAccent.shade100 : Colors.white,
                                size: 20,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              onPressed: _toggleMute,
                              tooltip: _isMuted ? 'Unmute' : 'Mute',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

