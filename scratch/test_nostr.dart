import 'dart:async';
import 'package:dart_nostr/dart_nostr.dart';

void main() async {
  Nostr.instance.disableLogs();
  await Nostr.instance.connect([
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.snort.social'
  ]);
  print("Connected to relays.");

  final request = NostrRequest(
    filters: [
      NostrFilter(
        kinds: [14445],
        since: DateTime.now().subtract(const Duration(days: 7)),
        limit: 100,
      ),
      NostrFilter(
        kinds: [21111],
        since: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
    ],
  );

  final sub = Nostr.instance.subscribeRequest(request);
  sub.fold(
    (subscription) {
      subscription.stream.listen((event) {
        print("Received event kind ${event.kind}: ${event.content}");
      });
    },
    (failure) => print("Failed to subscribe: ${failure.message}")
  );

  await Future.delayed(Duration(seconds: 15));
  print("Done waiting.");
  await Nostr.instance.disconnect();
}
