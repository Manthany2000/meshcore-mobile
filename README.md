# MeshCore Mobile

A phone chat app for a MeshCore node running companion firmware, over Bluetooth LE. The iPhone and Android
companion to [MeshCore Desktop](https://github.com/Manthany2000/meshcore-desktop), built with Flutter and speaking
the same protocol.

> **v0.2, early.** Works against the built-in simulator; real-node testing in progress.

- Channels and direct messages, with unread counts and `@[Name]` mentions highlighted
- Replies: long-press a channel message
- Repeats: how many relayed copies your node heard of each message, which repeaters relayed it, which you heard
  directly and at what SNR, and the path it took (tap a message)
- Delivery status on DMs (✓ on air, ✓✓ delivered with round-trip time, ✗ no ack; long-press → send again)
- **Map**: contacts by type on OpenStreetMap with filters (type, last heard), search and labels; every flood your
  node hears runs its path across the map; show a contact's stored route
- **Trace message**: long-press a received message (or open its details) → *Trace on map* draws the path it took in red
- **Network**: a graph of who relays through whom; tap a node to light up its links
- **Dashboard**: nodes heard, repeaters, messages and packets; busiest repeaters; channel activity; live packets
- **Packet waterfall**, like an SDR's: each packet lands by its SNR and scrolls down; tap it for the big one with
  axes, minutes of history, and tap a spot for its packet
- **Repeater management**: log in, status (battery, uptime, noise, counters) with live refresh, battery/noise/RSSI
  history charts, a console with presets, read and apply settings, adverts, reset route
- Contacts with type, hops, distance and last heard; full details (route by repeater name, bearing, SNR, key);
  reset route; always flood
- Add `#hashtag` or private channels, remove channels (long-press)
- Zero-hop or flood adverts; sets the node's clock if it's behind
- Live packet feed on the Node tab
- Messages saved per node on the phone; reconnects by itself when the link drops
- Light and dark themes that follow the phone
- A simulator (**Try the simulator** on the connect screen) to try it with no radio

USB serial isn't available: iPhones don't allow it without Apple's accessory programme.

## Install on an iPhone

Each push to `main` builds an unsigned `.ipa` on GitHub Actions (macOS runner). To put it on your phone:

1. Download **MeshCore-Mobile-ios** from the latest run on the Actions tab (or the `.ipa` on a release).
2. Sideload it with [Sideloadly](https://sideloadly.io) (Windows/macOS) or AltStore, signing with your Apple ID.
   A free Apple ID's signature lasts 7 days, then re-sideload; a paid developer account lasts a year.
3. On the phone: Settings → General → VPN & Device Management → trust your Apple ID. On iOS 16+, also turn on
   Settings → Privacy & Security → Developer Mode.

The first time you connect, iOS asks for the node's Bluetooth PIN itself.

## Android

The same workflow builds `MeshCore-Mobile.apk`; install it directly.

## Developing

```
flutter pub get
flutter test                 # protocol vectors shared with MeshCore Desktop, and a full session against the simulator
flutter run -d linux         # desktop window, real BLE through BlueZ
flutter run -d linux --dart-define=SIM=true   # straight into the simulator
```

Code layout: `lib/src/protocol.dart` (frames), `model.dart` (state, repeats, history), `session.dart` (sync and
commands), `transport.dart` (BLE), `sim.dart` (pretend node), `ui/`.

Bluetooth is [flutter_blue_plus](https://pub.dev/packages/flutter_blue_plus), used under its non-commercial licence.
