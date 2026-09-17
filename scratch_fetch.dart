import 'dart:async';
import 'package:dart_nostr/dart_nostr.dart';

void main() async {
  Nostr.instance.disableLogs();
  
  await Nostr.instance.connect([
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.snort.social'
  ]);

  print("Connected. Fetching 10446 events...");

  final request = NostrRequest(
    filters: [
      NostrFilter(
        kinds: [10446],
        limit: 10,
      ),
    ],
  );

  final sub = Nostr.instance.subscribeRequest(request);
  
  int count = 0;
  sub.fold(
    (subscription) {
      subscription.stream.listen((event) {
        print("Found event: ${event.pubkey} - Size: ${event.content?.length}");
        count++;
      });
    },
    (failure) => print("Failed to subscribe: ${failure.message}")
  );

  await Future.delayed(Duration(seconds: 10));
  print("Found $count events total.");
  
  await Nostr.instance.disconnect();
}
