import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aisat_connect/models/media_payload.dart';
import 'package:aisat_connect/services/storage_router.dart';
import 'package:aisat_connect/services/voice_note_service.dart';
import 'package:aisat_connect/ui/widgets/media_send_preview_screen.dart';

void main() {
  group('MediaPayload Unit Tests', () {
    test('Image payload serialization and deserialization', () {
      final imagePayload = MediaPayload(
        mediaType: 'image',
        url: 'https://blossom.primal.net/abc123hash',
        key: 'base64key==',
        nonce: 'base64nonce==',
        mac: 'base64mac==',
        fileHash: 'abc123hash',
        fileName: 'photo_test.jpg',
        fileSize: 1048576,
        mimeType: 'image/jpeg',
        thumbnail: 'data:image/jpeg;base64,/9j/4AAQSkZJRg==',
        width: 1920,
        height: 1080,
      );

      expect(imagePayload.isImage, isTrue);
      expect(imagePayload.isVideo, isFalse);
      expect(imagePayload.isDocument, isFalse);
      expect(imagePayload.isAudio, isFalse);
      expect(imagePayload.isVoiceNote, isFalse);

      final jsonMap = imagePayload.toJson();
      expect(jsonMap['mediaType'], equals('image'));
      expect(jsonMap['fileName'], equals('photo_test.jpg'));
      expect(jsonMap['width'], equals(1920));
      expect(jsonMap['height'], equals(1080));
      expect(jsonMap['thumbnail'], equals('data:image/jpeg;base64,/9j/4AAQSkZJRg=='));

      final serialized = imagePayload.serialize();
      expect(MediaPayload.isMedia(serialized), isTrue);

      final parsed = MediaPayload.tryParse(serialized);
      expect(parsed, isNotNull);
      expect(parsed!.mediaType, equals('image'));
      expect(parsed.url, equals('https://blossom.primal.net/abc123hash'));
      expect(parsed.fileName, equals('photo_test.jpg'));
      expect(parsed.fileSize, equals(1048576));
      expect(parsed.width, equals(1920));
      expect(parsed.height, equals(1080));
    });

    test('Video payload serialization and deserialization', () {
      final videoPayload = MediaPayload(
        mediaType: 'video',
        url: 'https://cdn.satellite.earth/video456',
        key: 'keyvid==',
        nonce: 'noncevid==',
        mac: 'macvid==',
        fileHash: 'video456',
        fileName: 'clip.mp4',
        fileSize: 5242880,
        mimeType: 'video/mp4',
        durationMs: 15400,
        thumbnail: 'data:image/jpeg;base64,thumb==',
      );

      expect(videoPayload.isVideo, isTrue);
      expect(videoPayload.durationMs, equals(15400));

      final serialized = videoPayload.serialize();
      final parsed = MediaPayload.tryParse(serialized);
      expect(parsed, isNotNull);
      expect(parsed!.isVideo, isTrue);
      expect(parsed.durationMs, equals(15400));
      expect(parsed.mimeType, equals('video/mp4'));
    });

    test('Document payload serialization and deserialization', () {
      final docPayload = MediaPayload(
        mediaType: 'document',
        url: 'https://nostr.download/doc789',
        key: 'keydoc==',
        nonce: 'noncedoc==',
        mac: 'macdoc==',
        fileHash: 'doc789',
        fileName: 'Project_Report.pdf',
        fileSize: 204800,
        mimeType: 'application/pdf',
      );

      expect(docPayload.isDocument, isTrue);
      expect(docPayload.fileName, equals('Project_Report.pdf'));

      final networkJson = docPayload.toNetworkJson();
      expect(networkJson.containsKey('localPath'), isFalse);
      expect(networkJson['fileName'], equals('Project_Report.pdf'));
    });

    test('MediaPayload with caption serialization and network json', () {
      final payload = MediaPayload(
        mediaType: 'image',
        url: 'https://blossom.primal.net/caption_test',
        key: 'key==',
        nonce: 'nonce==',
        mac: 'mac==',
        fileHash: 'hash123',
        fileName: 'captioned_photo.jpg',
        fileSize: 1024,
        mimeType: 'image/jpeg',
        caption: 'Look at this stunning view! #travel',
      );

      expect(payload.caption, equals('Look at this stunning view! #travel'));

      final jsonMap = payload.toJson();
      expect(jsonMap['caption'], equals('Look at this stunning view! #travel'));

      final networkJson = payload.toNetworkJson();
      expect(networkJson['caption'], equals('Look at this stunning view! #travel'));

      final serialized = payload.serialize();
      final parsed = MediaPayload.tryParse(serialized);
      expect(parsed, isNotNull);
      expect(parsed!.caption, equals('Look at this stunning view! #travel'));
    });

    test('OutgoingMediaItem and MediaSendResult data structures', () {
      final item1 = OutgoingMediaItem(
        path: '/tmp/test_image.jpg',
        name: 'test_image.jpg',
        mediaType: 'image',
        byteSize: 1024,
      );
      final item2 = OutgoingMediaItem(
        path: '/tmp/test_video.mp4',
        name: 'test_video.mp4',
        mediaType: 'video',
        byteSize: 4096,
      );

      final result = MediaSendResult(
        items: [item1, item2],
        caption: 'Holiday clips',
      );

      expect(result.items.length, equals(2));
      expect(result.caption, equals('Holiday clips'));
      expect(result.items[0].mediaType, equals('image'));
      expect(result.items[1].mediaType, equals('video'));
    });

    test('Legacy VoiceNotePayload backward compatibility', () {
      final vn = VoiceNotePayload(
        url: 'https://blossom.primal.net/vn001',
        key: 'legacykey==',
        nonce: 'legacynonce==',
        mac: 'legacymac==',
        fileHash: 'vn001',
        durationMs: 3500,
        waveform: [10, 45, 90, 30],
        sentAt: 1700000000000,
        localPath: '/tmp/vn.m4a',
      );

      // Convert legacy to MediaPayload
      final mediaFromVn = MediaPayload.fromVoiceNotePayload(vn);
      expect(mediaFromVn.isVoiceNote, isTrue);
      expect(mediaFromVn.mediaType, equals('voice'));
      expect(mediaFromVn.durationMs, equals(3500));
      expect(mediaFromVn.waveform, equals([10, 45, 90, 30]));
      expect(mediaFromVn.localPath, equals('/tmp/vn.m4a'));

      // Convert back to VoiceNotePayload
      final convertedBack = mediaFromVn.toVoiceNotePayload();
      expect(convertedBack.url, equals(vn.url));
      expect(convertedBack.durationMs, equals(vn.durationMs));
      expect(convertedBack.waveform, equals(vn.waveform));

      // Test parsing legacy JSON string with "type":"voice"
      final legacyJsonString = jsonEncode({
        'type': 'voice',
        'url': 'https://blossom.primal.net/vn002',
        'key': 'k==',
        'nonce': 'n==',
        'mac': 'm==',
        'fileHash': 'vn002',
        'durationMs': 4200,
        'waveform': [5, 15, 25],
      });

      expect(MediaPayload.isMedia(legacyJsonString), isTrue);
      final parsedLegacy = MediaPayload.tryParse(legacyJsonString);
      expect(parsedLegacy, isNotNull);
      expect(parsedLegacy!.isVoiceNote, isTrue);
      expect(parsedLegacy.durationMs, equals(4200));
      expect(parsedLegacy.waveform, equals([5, 15, 25]));
    });

    test('Enveloped media payload parsing', () {
      final inner = jsonEncode({
        'type': 'media',
        'mediaType': 'image',
        'url': 'https://blossom.primal.net/envimage',
        'key': 'k==',
        'nonce': 'n==',
        'mac': 'm==',
        'fileHash': 'envimage',
        'fileName': 'wrapped.png',
        'fileSize': 1000,
        'mimeType': 'image/png',
      });

      final envelopeJson = jsonEncode({
        'type': 'media',
        'body': {
          'text': inner,
        },
      });

      expect(MediaPayload.isMedia(envelopeJson), isTrue);
      final parsed = MediaPayload.tryParse(envelopeJson);
      expect(parsed, isNotNull);
      expect(parsed!.isImage, isTrue);
      expect(parsed.fileName, equals('wrapped.png'));
    });
  });

  group('StorageRouter and BlossomServerMetric Tests', () {
    test('BlossomServerMetric EMA calculation and failure penalty', () {
      final metric = BlossomServerMetric(
        uploadUrl: 'https://test.server/upload',
        getBaseUrl: 'https://test.server',
        movingAverageLatencyMs: 400.0,
      );

      // Record fast success (100ms)
      // EMA = 400 * 0.7 + 100 * 0.3 = 280 + 30 = 310ms
      metric.recordSuccess(100);
      expect(metric.movingAverageLatencyMs, closeTo(310.0, 0.01));
      expect(metric.consecutiveFailures, equals(0));

      // Record failure (penalized by +4000ms)
      metric.recordFailure();
      expect(metric.consecutiveFailures, equals(1));
      expect(metric.movingAverageLatencyMs, closeTo(4310.0, 0.01));
    });

    test('StorageRouter server priority ranking', () {
      final router = StorageRouter();
      final ranked = router.rankedServers;
      expect(ranked.isNotEmpty, isTrue);

      // Verify list is sorted ascending by latency
      for (int i = 0; i < ranked.length - 1; i++) {
        expect(
          ranked[i].movingAverageLatencyMs <= ranked[i + 1].movingAverageLatencyMs,
          isTrue,
        );
      }
    });
  });
}
