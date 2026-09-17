import 'dart:convert';
import 'package:dart_nostr/dart_nostr.dart';

void main() async {
  print("Connecting to relays...");
  await Nostr.instance.connect([
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.snort.social'
  ]);
  
  print("Connected. Querying for latest 14446 events...");
  final request = NostrRequest(
    filters: [
      NostrFilter(kinds: [14446], limit: 20), // Get latest 20
    ],
  );
  
  final sub = Nostr.instance.subscribeRequest(request);
  
  sub.fold(
    (subscription) {
      subscription.stream.listen((event) {
        print("--- Found event from author: ${event.pubkey} ---");
        try {
          final map = jsonDecode(event.content!);
          if (map.containsKey('masterKey') && map.containsKey('oneTimePreKeys')) {
            print("VALID AISAT CONNECT BUNDLE! masterKey: ${map['masterKey']}");
          } else {
            print("Not an AISAT Connect bundle.");
          }
        } catch (e) {
          print("Not valid JSON.");
        }
      });
    },
    (failure) => print("Failed to subscribe: ${failure.message}")
  );
  
  await Future.delayed(Duration(seconds: 5));
  print("Done.");
  await Nostr.instance.disconnect();
}
