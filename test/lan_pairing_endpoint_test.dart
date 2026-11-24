import 'dart:convert';
import 'dart:io';

import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_qr.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _LocalIo extends HttpOverrides {}

void main() {
  test(
    'Other NIC discovery cannot replace the endpoint paired by scanning QR',
    () async {
      HttpOverrides.global = _LocalIo();
      LanService device(String name) => LanService(
        store: StateStore.memory({'lanDeviceName': name}),
        files: LanFiles(android: false),
        requestedPort: 0,
        requestedDiscoveryPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        addresses: () async => ['127.0.0.1'],
      );
      final sender = device('QR sender'), receiver = device('QR scanner');
      LanPeer peerFor(LanService service, String id) =>
          service.peers.singleWhere((peer) => peer.id == id);
      final alternate = await RawDatagramSocket.bind(
        InternetAddress('127.0.0.2'),
        0,
      );
      final original = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      try {
        await sender.start();
        final qr = LanQrTarget.parse(sender.connectionQr()) as LanConnectionQr;
        final peer = await receiver.connectQr(qr);
        expect(receiver.connected(peer), isTrue);
        alternate.send(
          utf8.encode(
            jsonEncode({
              'protocol': lanProtocol,
              'id': sender.id,
              'name': 'QR sender renamed',
              'port': sender.port,
              'discover': true,
            }),
          ),
          InternetAddress.loopbackIPv4,
          receiver.discoveryPort,
        );
        await until(
          () => peerFor(receiver, sender.id).name == 'QR sender renamed',
        );
        final discovered = peerFor(receiver, sender.id);
        expect(discovered.base, peer.base);
        expect(receiver.connected(discovered), isTrue);
        await receiver.sendMessage(discovered, 'QR pairing still usable');
        expect(sender.inbox.single.value, 'QR pairing still usable');
        final reverse = peerFor(sender, receiver.id);
        alternate.send(
          utf8.encode(
            jsonEncode({
              'protocol': lanProtocol,
              'id': receiver.id,
              'name': 'QR scanner renamed',
              'port': receiver.port,
            }),
          ),
          InternetAddress.loopbackIPv4,
          sender.discoveryPort,
        );
        await until(
          () => peerFor(sender, receiver.id).name == 'QR scanner renamed',
        );
        expect(peerFor(sender, receiver.id).base, reverse.base);
        expect(sender.connected(peerFor(sender, receiver.id)), isTrue);
        await sender.sendMessage(
          peerFor(sender, receiver.id),
          'QR reply still usable',
        );
        expect(receiver.inbox.single.value, 'QR reply still usable');

        // A restart on the selected IP must still invalidate its former session.
        final newPort = sender.port == 65535
            ? sender.port - 1
            : sender.port + 1;
        original.send(
          utf8.encode(
            jsonEncode({
              'protocol': lanProtocol,
              'id': sender.id,
              'name': sender.name,
              'port': newPort,
            }),
          ),
          InternetAddress.loopbackIPv4,
          receiver.discoveryPort,
        );
        await until(() => peerFor(receiver, sender.id).port == newPort);
        expect(receiver.connected(peerFor(receiver, sender.id)), isFalse);
      } finally {
        alternate.close();
        original.close();
        await sender.close();
        await receiver.close();
        HttpOverrides.global = null;
      }
    },
  );
}

