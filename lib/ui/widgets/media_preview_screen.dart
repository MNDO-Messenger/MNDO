import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:video_player/video_player.dart';
import 'package:pdfx/pdfx.dart';

/// Fullscreen Telegram-style media viewer for Images, Videos, and PDFs.
/// Renders completely inside the application without relying on external system viewers.
class MediaPreviewScreen extends StatefulWidget {
  final String filePath;
  final String title;
  final String mediaType; // 'image', 'video', 'document', 'audio'

  const MediaPreviewScreen({
    super.key,
    required this.filePath,
    required this.title,
    required this.mediaType,
  });

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  bool _showOverlay = true;

  bool get _isPdf {
    final lowerPath = widget.filePath.toLowerCase();
    final lowerTitle = widget.title.toLowerCase();
    return lowerPath.endsWith('.pdf') || lowerTitle.endsWith('.pdf');
  }

  void _toggleOverlay() {
    setState(() {
      _showOverlay = !_showOverlay;
    });
  }

  String _getFileSizeString(File file) {
    try {
      final bytes = file.lengthSync();
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = File(widget.filePath);
    final exists = file.existsSync();
    final sizeStr = exists ? _getFileSizeString(file) : '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. In-App Content Viewer
          Positioned.fill(
            child: !exists
                ? const Center(
                    child: Text(
                      'Media file not found or still downloading',
                      style: TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  )
                : _buildViewer(context),
          ),

          // 2. Telegram Floating Header
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            top: _showOverlay ? 0 : -100,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8,
                bottom: 12,
                left: 12,
                right: 12,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.85),
                    Colors.black.withValues(alpha: 0.0),
                  ],
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (sizeStr.isNotEmpty)
                          Text(
                            sizeStr,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (exists)
                    IconButton(
                      icon: const Icon(Icons.open_in_new_rounded, color: Colors.white),
                      tooltip: 'Open with external system app',
                      onPressed: () => OpenFilex.open(widget.filePath),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewer(BuildContext context) {
    if (widget.mediaType == 'image') {
      return _InAppImageViewer(
        filePath: widget.filePath,
        onTap: _toggleOverlay,
      );
    } else if (widget.mediaType == 'video') {
      return _InAppVideoPlayer(
        filePath: widget.filePath,
        showOverlay: _showOverlay,
        onToggleOverlay: _toggleOverlay,
      );
    } else if (_isPdf) {
      return _InAppPdfViewer(
        filePath: widget.filePath,
        onTap: _toggleOverlay,
      );
    } else {
      return _GenericFileViewer(
        filePath: widget.filePath,
        title: widget.title,
        mediaType: widget.mediaType,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// 1. IN-APP TELEGRAM IMAGE VIEWER WITH DOUBLE-TAP ZOOM & PINCH
// ---------------------------------------------------------------------------
class _InAppImageViewer extends StatefulWidget {
  final String filePath;
  final VoidCallback onTap;

  const _InAppImageViewer({
    required this.filePath,
    required this.onTap,
  });

  @override
  State<_InAppImageViewer> createState() => _InAppImageViewerState();
}

class _InAppImageViewerState extends State<_InAppImageViewer>
    with SingleTickerProviderStateMixin {
  final TransformationController _transformController = TransformationController();
  late AnimationController _animationController;
  Animation<Matrix4>? _zoomAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        if (_zoomAnimation != null) {
          _transformController.value = _zoomAnimation!.value;
        }
      });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    final currentScale = _transformController.value.getMaxScaleOnAxis();
    final endScale = currentScale > 1.2 ? 1.0 : 2.5;

    Matrix4 targetMatrix;
    if (endScale == 1.0) {
      targetMatrix = Matrix4.identity();
    } else {
      final position = details.localPosition;
      targetMatrix = Matrix4.diagonal3Values(endScale, endScale, 1.0)
        ..setTranslationRaw(-position.dx * (endScale - 1), -position.dy * (endScale - 1), 0.0);
    }

    _zoomAnimation = Matrix4Tween(
      begin: _transformController.value,
      end: targetMatrix,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _animationController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: _handleDoubleTapDown,
      onDoubleTap: () {},
      child: Container(
        color: Colors.black,
        child: InteractiveViewer(
          transformationController: _transformController,
          minScale: 0.8,
          maxScale: 5.0,
          clipBehavior: Clip.none,
          child: Center(
            child: Image.file(
              File(widget.filePath),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Icon(
                Icons.broken_image_rounded,
                color: Colors.white38,
                size: 72,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. IN-APP TELEGRAM VIDEO PLAYER WITH SCRUBBER & PLAYBACK CONTROLS
// ---------------------------------------------------------------------------
class _InAppVideoPlayer extends StatefulWidget {
  final String filePath;
  final bool showOverlay;
  final VoidCallback onToggleOverlay;

  const _InAppVideoPlayer({
    required this.filePath,
    required this.showOverlay,
    required this.onToggleOverlay,
  });

  @override
  State<_InAppVideoPlayer> createState() => _InAppVideoPlayerState();
}

class _InAppVideoPlayerState extends State<_InAppVideoPlayer> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  String? _error;
  bool _isMuted = false;

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
        }
      }).catchError((err) {
        if (mounted) {
          setState(() {
            _error = err.toString();
          });
        }
      });

    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (!_isInitialized) return;
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        if (_controller.value.position >= _controller.value.duration) {
          _controller.seekTo(Duration.zero);
        }
        _controller.play();
      }
    });
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _controller.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text(
                'Unable to play video: $_error',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
      );
    }

    final isPlaying = _controller.value.isPlaying;
    final isFinished = _controller.value.position >= _controller.value.duration;
    final duration = _controller.value.duration;
    final position = _controller.value.position;

    return GestureDetector(
      onTap: widget.onToggleOverlay,
      child: Container(
        color: Colors.black,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Video view
            Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio > 0
                    ? _controller.value.aspectRatio
                    : 16 / 9,
                child: VideoPlayer(_controller),
              ),
            ),

            // Center Big Play / Replay button
            if (widget.showOverlay || !isPlaying)
              Center(
                child: GestureDetector(
                  onTap: _togglePlayPause,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24, width: 1.5),
                    ),
                    child: Icon(
                      isFinished
                          ? Icons.replay_rounded
                          : (isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                ),
              ),

            // Bottom Telegram Controls Bar
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              bottom: widget.showOverlay ? 0 : -90,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  bottom: MediaQuery.of(context).padding.bottom + 8,
                  top: 16,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.85),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Scrubber Slider
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        trackHeight: 3,
                        activeTrackColor: const Color(0xFF6366F1),
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: position.inMilliseconds
                            .clamp(0, duration.inMilliseconds)
                            .toDouble(),
                        max: duration.inMilliseconds.toDouble() > 0
                            ? duration.inMilliseconds.toDouble()
                            : 1.0,
                        onChanged: (val) {
                          _controller.seekTo(Duration(milliseconds: val.toInt()));
                        },
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                          onPressed: _togglePlayPause,
                        ),
                        Text(
                          '${_formatDuration(position)} / ${_formatDuration(duration)}',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(
                            _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          onPressed: _toggleMute,
                          tooltip: _isMuted ? 'Unmute' : 'Mute',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. IN-APP TELEGRAM PDF VIEWER WITH PINCH-TO-ZOOM & PAGE INDICATOR
// ---------------------------------------------------------------------------
class _InAppPdfViewer extends StatefulWidget {
  final String filePath;
  final VoidCallback onTap;

  const _InAppPdfViewer({
    required this.filePath,
    required this.onTap,
  });

  @override
  State<_InAppPdfViewer> createState() => _InAppPdfViewerState();
}

class _InAppPdfViewerState extends State<_InAppPdfViewer> {
  late PdfControllerPinch _pdfController;
  int _currentPage = 1;
  int _totalPages = 0;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    try {
      _pdfController = PdfControllerPinch(
        document: PdfDocument.openFile(widget.filePath),
      );
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
    }
  }

  @override
  void dispose() {
    _pdfController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text(
                'Could not open PDF: $_error',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        color: const Color(0xFF18181B),
        child: Stack(
          children: [
            PdfViewPinch(
              controller: _pdfController,
              onDocumentLoaded: (doc) {
                if (mounted) {
                  setState(() {
                    _totalPages = doc.pagesCount;
                    _isLoading = false;
                  });
                }
              },
              onPageChanged: (page) {
                if (mounted) {
                  setState(() {
                    _currentPage = page;
                  });
                }
              },
              onDocumentError: (err) {
                if (mounted) {
                  setState(() {
                    _error = err.toString();
                    _isLoading = false;
                  });
                }
              },
            ),

            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
              ),

            // Telegram Page Indicator Pill
            if (_totalPages > 0)
              Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      'Page $_currentPage of $_totalPages',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
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

// ---------------------------------------------------------------------------
// 4. GENERIC FILE VIEWER (FOR ARCHIVES, OTHER DOCUMENTS)
// ---------------------------------------------------------------------------
class _GenericFileViewer extends StatelessWidget {
  final String filePath;
  final String title;
  final String mediaType;

  const _GenericFileViewer({
    required this.filePath,
    required this.title,
    required this.mediaType,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              mediaType == 'audio' ? Icons.audiotrack_rounded : Icons.description_rounded,
              color: const Color(0xFF6366F1),
              size: 48,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open with External Application'),
            onPressed: () => OpenFilex.open(filePath),
          ),
        ],
      ),
    );
  }
}
