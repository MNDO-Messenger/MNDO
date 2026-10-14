import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../models/media_payload.dart';
import '../../services/media_service.dart';
import '../../services/media_cache_manager.dart';
import 'media_preview_screen.dart';

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
        ? (widget.isDark ? const Color(0xFF4F46E5) : const Color(0xFF6366F1))
        : (widget.isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF4F4F5));

    final timeColor = widget.isMine
        ? Colors.white70
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
    return GestureDetector(
      onTap: () {
        if (_localDecryptedPath != null && File(_localDecryptedPath!).existsSync()) {
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
          // Play button or Download button
          Container(
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
                    (_localDecryptedPath != null && File(_localDecryptedPath!).existsSync()) || widget.isMine
                        ? Icons.play_arrow_rounded
                        : (_downloadFailed ? Icons.refresh_rounded : Icons.download_rounded),
                    color: Colors.white,
                    size: 30,
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
                          ? Colors.white70
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
                color: widget.isMine ? Colors.white70 : Colors.black54,
              ),
          ],
        ),
      ),
    );
  }
}
