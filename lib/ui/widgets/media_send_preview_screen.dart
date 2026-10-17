import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

/// Data model representing a pending outgoing media item in the preview queue.
class OutgoingMediaItem {
  final String path;
  final String name;
  final String mediaType; // 'image', 'video', 'audio', 'document'
  final int byteSize;

  OutgoingMediaItem({
    required this.path,
    required this.name,
    required this.mediaType,
    required this.byteSize,
  });

  static OutgoingMediaItem fromFile(XFile file) {
    final ext = p.extension(file.path).toLowerCase();
    String mediaType = 'document';
    if (['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'].contains(ext)) {
      mediaType = 'image';
    } else if (['.mp4', '.mov', '.avi', '.mkv', '.webm'].contains(ext)) {
      mediaType = 'video';
    } else if (['.mp3', '.wav', '.m4a', '.aac', '.ogg', '.flac'].contains(ext)) {
      mediaType = 'audio';
    }

    int size = 0;
    try {
      size = File(file.path).lengthSync();
    } catch (_) {}

    return OutgoingMediaItem(
      path: file.path,
      name: file.name,
      mediaType: mediaType,
      byteSize: size,
    );
  }
}

/// Returned result from the media preview screen when the user confirms sending.
class MediaSendResult {
  final List<OutgoingMediaItem> items;
  final String? caption;

  MediaSendResult({
    required this.items,
    this.caption,
  });
}

/// Intermediate Media Preview & Send Screen (Telegram & WhatsApp style).
/// Displays interactive preview, thumbnail album strip, Add Media (+) button,
/// caption input, and #2B5278 send button.
class MediaSendPreviewScreen extends StatefulWidget {
  final List<OutgoingMediaItem> initialItems;
  final String recipientName;

  const MediaSendPreviewScreen({
    super.key,
    required this.initialItems,
    required this.recipientName,
  });

  @override
  State<MediaSendPreviewScreen> createState() => _MediaSendPreviewScreenState();
}

class _MediaSendPreviewScreenState extends State<MediaSendPreviewScreen> {
  late List<OutgoingMediaItem> _items;
  int _currentIndex = 0;
  late PageController _pageController;
  final TextEditingController _captionController = TextEditingController();
  final ScrollController _thumbnailScrollController = ScrollController();

  static const Color _brandColor = Color(0xFF2B5278);

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.initialItems);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _captionController.dispose();
    _thumbnailScrollController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _scrollToThumbnail(index);
  }

  void _scrollToThumbnail(int index) {
    if (!_thumbnailScrollController.hasClients) return;
    final targetOffset = index * 62.0;
    _thumbnailScrollController.animateTo(
      targetOffset.clamp(0.0, _thumbnailScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _pickMoreMedia() async {
    try {
      const typeGroup = XTypeGroup(
        label: 'Media and Documents',
        extensions: [
          'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp',
          'mp4', 'mov', 'avi', 'mkv', 'webm',
          'mp3', 'wav', 'm4a', 'aac', 'ogg',
          'pdf', 'doc', 'docx', 'zip', 'txt'
        ],
      );

      final newFiles = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (newFiles.isEmpty || !mounted) return;

      final newItems = newFiles.map(OutgoingMediaItem.fromFile).toList();
      setState(() {
        _items.addAll(newItems);
        _currentIndex = _items.length - newItems.length;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) {
          _pageController.jumpToPage(_currentIndex);
        }
        _scrollToThumbnail(_currentIndex);
      });
    } catch (e) {
      debugPrint('[MEDIA_PREVIEW] Error picking more media: $e');
    }
  }

  void _removeCurrentItem() {
    if (_items.isEmpty) return;

    if (_items.length == 1) {
      Navigator.pop(context);
      return;
    }

    setState(() {
      _items.removeAt(_currentIndex);
      if (_currentIndex >= _items.length) {
        _currentIndex = _items.length - 1;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
      _scrollToThumbnail(_currentIndex);
    });
  }

  void _removeItemAtIndex(int index) {
    if (_items.length == 1) {
      Navigator.pop(context);
      return;
    }

    setState(() {
      _items.removeAt(index);
      if (_currentIndex >= _items.length) {
        _currentIndex = _items.length - 1;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
      _scrollToThumbnail(_currentIndex);
    });
  }

  void _send() {
    if (_items.isEmpty) return;

    final captionText = _captionController.text.trim();
    Navigator.pop(
      context,
      MediaSendResult(
        items: _items,
        caption: captionText.isNotEmpty ? captionText : null,
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = (_items.isNotEmpty && _currentIndex < _items.length)
        ? _items[_currentIndex]
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          children: [
            // 1. Top Bar
            _buildTopBar(currentItem),

            // 2. Main Media Viewport
            Expanded(
              child: _items.isEmpty
                  ? const SizedBox.shrink()
                  : PageView.builder(
                      controller: _pageController,
                      itemCount: _items.length,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (context, index) {
                        return _buildItemPreview(_items[index]);
                      },
                    ),
            ),

            // 3. Bottom Carousel (Thumbnails + Add Media Button)
            _buildThumbnailStrip(),

            // 4. Caption Input & Send Bar
            _buildCaptionAndSendBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(OutgoingMediaItem? currentItem) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
            tooltip: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.recipientName.isNotEmpty ? widget.recipientName : 'Send media',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_items.length > 1)
                  Text(
                    '${_currentIndex + 1} of ${_items.length}',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          if (currentItem != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: Colors.white70, size: 22),
              tooltip: 'Delete item',
              onPressed: _removeCurrentItem,
            ),
        ],
      ),
    );
  }

  Widget _buildItemPreview(OutgoingMediaItem item) {
    if (item.mediaType == 'image') {
      return Center(
        child: InteractiveViewer(
          minScale: 0.9,
          maxScale: 4.0,
          child: Image.file(
            File(item.path),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image_rounded, color: Colors.white54, size: 54),
            ),
          ),
        ),
      );
    } else if (item.mediaType == 'video') {
      return _SendVideoPreview(filePath: item.path);
    } else if (item.mediaType == 'audio') {
      return _buildAudioCard(item);
    } else {
      return _buildDocumentCard(item);
    }
  }

  Widget _buildAudioCard(OutgoingMediaItem item) {
    final sizeStr = _formatFileSize(item.byteSize);
    return Center(
      child: Container(
        margin: const EdgeInsets.all(28),
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF2E2E2E), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _brandColor.withValues(alpha: 0.2),
                shape: BoxShape.circle,
                border: Border.all(color: _brandColor, width: 1.5),
              ),
              child: const Icon(
                Icons.audiotrack_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              item.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            if (sizeStr.isNotEmpty)
              Text(
                sizeStr,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 13,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentCard(OutgoingMediaItem item) {
    final ext = item.name.contains('.')
        ? item.name.split('.').last.toUpperCase()
        : 'DOC';
    final sizeStr = _formatFileSize(item.byteSize);

    Color extColor = Colors.teal;
    if (ext == 'PDF') extColor = Colors.redAccent;
    if (['DOC', 'DOCX'].contains(ext)) extColor = Colors.blueAccent;
    if (['ZIP', 'RAR', '7Z'].contains(ext)) extColor = Colors.orangeAccent;

    return Center(
      child: Container(
        margin: const EdgeInsets.all(28),
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF2E2E2E), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: extColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: extColor, width: 1.5),
              ),
              child: Center(
                child: Text(
                  ext.length > 4 ? ext.substring(0, 4) : ext,
                  style: TextStyle(
                    color: extColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              item.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            if (sizeStr.isNotEmpty)
              Text(
                sizeStr,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 13,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailStrip() {
    return Container(
      height: 68,
      margin: const EdgeInsets.only(top: 8, bottom: 6),
      child: ListView.builder(
        controller: _thumbnailScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _items.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            // "Add Media" Button (+)
            return GestureDetector(
              onTap: _pickMoreMedia,
              child: Container(
                width: 52,
                height: 52,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white24,
                    width: 1.2,
                  ),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_rounded, color: Colors.white, size: 22),
                    SizedBox(height: 2),
                    Text(
                      'Add',
                      style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            );
          }

          final itemIndex = index - 1;
          final item = _items[itemIndex];
          final isSelected = itemIndex == _currentIndex;

          return GestureDetector(
            onTap: () {
              setState(() {
                _currentIndex = itemIndex;
              });
              _pageController.animateToPage(
                itemIndex,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
              );
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 52,
                  height: 52,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? _brandColor : Colors.transparent,
                      width: isSelected ? 2.5 : 0.8,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _buildThumbnailImage(item),
                  ),
                ),
                // Small remove 'x' badge if multiple items
                if (_items.length > 1)
                  Positioned(
                    top: -4,
                    right: 4,
                    child: GestureDetector(
                      onTap: () => _removeItemAtIndex(itemIndex),
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(
                          color: Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildThumbnailImage(OutgoingMediaItem item) {
    if (item.mediaType == 'image') {
      return Image.file(
        File(item.path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: const Color(0xFF262626),
          child: const Icon(Icons.image_outlined, color: Colors.white54, size: 24),
        ),
      );
    } else if (item.mediaType == 'video') {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Icon(Icons.videocam_rounded, color: Colors.white, size: 24),
        ),
      );
    } else if (item.mediaType == 'audio') {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Icon(Icons.audiotrack_rounded, color: Colors.white, size: 24),
        ),
      );
    } else {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Icon(Icons.insert_drive_file_rounded, color: Colors.white, size: 24),
        ),
      );
    }
  }

  Widget _buildCaptionAndSendBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Expandable Caption Field
          Expanded(
            child: Container(
              constraints: const BoxConstraints(
                minHeight: 46,
                maxHeight: 120,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF2E2E2E), width: 1),
              ),
              child: TextField(
                controller: _captionController,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(
                  fontSize: 15,
                  color: Colors.white,
                ),
                decoration: const InputDecoration(
                  hintText: 'Add a caption...',
                  hintStyle: TextStyle(
                    fontSize: 15,
                    color: Colors.white54,
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Send Button
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _brandColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _brandColor.withValues(alpha: 0.38),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Icons.send_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// In-App Video Preview with scrubber progress bar, mute/unmute button, and play/pause controls.
class _SendVideoPreview extends StatefulWidget {
  final String filePath;

  const _SendVideoPreview({required this.filePath});

  @override
  State<_SendVideoPreview> createState() => _SendVideoPreviewState();
}

class _SendVideoPreviewState extends State<_SendVideoPreview> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  bool _isMuted = false;
  bool _showOverlay = true;
  bool _isDragging = false;
  double _dragPosition = 0.0;
  Timer? _hideOverlayTimer;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final ctrl = VideoPlayerController.file(File(widget.filePath));
      await ctrl.initialize();
      if (!mounted) {
        ctrl.dispose();
        return;
      }
      setState(() {
        _controller = ctrl;
        _isInitialized = true;
      });
      ctrl.addListener(() {
        if (mounted) setState(() {});
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _hasError = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _hideOverlayTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _startHideTimer() {
    _hideOverlayTimer?.cancel();
    _hideOverlayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controller?.value.isPlaying == true && !_isDragging) {
        setState(() {
          _showOverlay = false;
        });
      }
    });
  }

  void _togglePlayPause() {
    final ctrl = _controller;
    if (ctrl == null || !_isInitialized) return;
    setState(() {
      if (ctrl.value.isPlaying) {
        ctrl.pause();
        _showOverlay = true;
        _hideOverlayTimer?.cancel();
      } else {
        if (ctrl.value.position >= ctrl.value.duration) {
          ctrl.seekTo(Duration.zero);
        }
        ctrl.play();
        _showOverlay = true;
        _startHideTimer();
      }
    });
  }

  void _toggleMute() {
    final ctrl = _controller;
    if (ctrl == null) return;
    setState(() {
      _isMuted = !_isMuted;
      ctrl.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  void _onTapVideo() {
    setState(() {
      _showOverlay = !_showOverlay;
    });
    if (_showOverlay && _controller?.value.isPlaying == true) {
      _startHideTimer();
    } else {
      _hideOverlayTimer?.cancel();
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.videocam_rounded, color: Colors.white70, size: 64),
            SizedBox(height: 12),
            Text(
              'Video Preview',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    final ctrl = _controller;
    if (!_isInitialized || ctrl == null) {
      return const Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70),
        ),
      );
    }

    final isPlaying = ctrl.value.isPlaying;
    final isFinished = ctrl.value.position >= ctrl.value.duration;
    final durationMs = ctrl.value.duration.inMilliseconds.toDouble();
    final currentPosMs = _isDragging
        ? _dragPosition
        : ctrl.value.position.inMilliseconds.toDouble();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTapVideo,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Video Player
          Center(
            child: AspectRatio(
              aspectRatio: ctrl.value.aspectRatio > 0 ? ctrl.value.aspectRatio : 16 / 9,
              child: VideoPlayer(ctrl),
            ),
          ),

          // 2. Big Center Play/Pause/Replay Button
          if (_showOverlay || !isPlaying)
            GestureDetector(
              onTap: _togglePlayPause,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white30, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Icon(
                  isFinished
                      ? Icons.replay_rounded
                      : (isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  color: Colors.white,
                  size: 34,
                ),
              ),
            ),

          // 3. Bottom Controls Overlay: Scrubber Progress Bar & Mute Button
          Positioned(
            left: 12,
            right: 12,
            bottom: 8,
            child: AnimatedOpacity(
              opacity: _showOverlay ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showOverlay,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Video Progress Bar (Scrubber)
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.5,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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
                            _hideOverlayTimer?.cancel();
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
                            _controller?.seekTo(Duration(milliseconds: val.toInt()));
                            setState(() {
                              _isDragging = false;
                            });
                            if (isPlaying) {
                              _startHideTimer();
                            }
                          },
                        ),
                      ),
                      // Controls Row: Play/Pause, Time, Mute Button
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                isFinished
                                    ? Icons.replay_rounded
                                    : (isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                color: Colors.white,
                                size: 22,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              onPressed: _togglePlayPause,
                              tooltip: isPlaying ? 'Pause' : 'Play',
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${_formatDuration(Duration(milliseconds: currentPosMs.toInt()))} / ${_formatDuration(ctrl.value.duration)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            // Mute/Unmute Button
                            IconButton(
                              icon: Icon(
                                _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                                color: _isMuted ? Colors.redAccent.shade100 : Colors.white,
                                size: 22,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              onPressed: _toggleMute,
                              tooltip: _isMuted ? 'Unmute' : 'Mute',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

