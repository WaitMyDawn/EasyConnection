import 'dart:convert';
import 'dart:io';

import 'package:easy_connection/connection.dart';

class ForcedProxy extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'PROXY 127.0.0.1:1';
}

Future<void> main() async {
  try {
    final line = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final invitation = PairingInvitation.parse(line);
    await HttpOverrides.runWithHttpOverrides(() async {
      final wrong = PairingInvitation(
        hostName: invitation.hostName,
        endpoints: invitation.endpoints,
        fingerprint: List.filled(64, '0').join(),
        code: invitation.code,
        expiresAt: invitation.expiresAt,
      );
      try {
        await DesktopClient.pairInvitation(wrong);
        throw StateError('Pin mismatch was accepted');
      } on ConnectionException catch (error) {
        if (!error.failures.any((f) => f.kind == 'certificate_mismatch')) {
          throw StateError('Pin rejection was not identified');
        }
      }
      final profile = await DesktopClient.pairInvitation(invitation);
      final client = DesktopClient(profile);
      try {
        final status = await client.connect();
        if (status['protocolVersion'] != 1) {
          throw StateError('Protocol mismatch');
        }
        final snapshot = await client.post('/api/v1/snapshots', {
          'type': 'screenshot',
          'displayId': 'fixture',
        }) as Json;
        final image = await client.image(snapshot['id'] as String);
        if (image.length < 100 || image[0] != 255 || image[1] != 216) {
          throw StateError('Invalid screenshot');
        }
        final focus = await client.get('/api/v1/focus') as Json;
        if (focus['id'] is! String || focus['windowId'] is! String) {
          throw StateError('Invalid focus metadata');
        }
        final interaction = await client.post('/api/v1/interactions', {
          'requestId': requestId(),
          'action': {
            'type': 'movePointer',
            'snapshotId': snapshot['id'],
            'deltaX': 1,
          },
        }) as Json;
        if (interaction['cursor'] is! Map) {
          throw StateError('Missing interaction cursor');
        }
        final socket = await client.live('fixture');
        try {
          final frames = await socket
              .take(2)
              .toList()
              .timeout(const Duration(seconds: 5));
          if (frames[0] is! String || frames[1] is! List<int>) {
            throw StateError('Invalid live stream');
          }
        } finally {
          await socket.close();
        }
      } finally {
        client.close();
      }
    }, ForcedProxy());
    stdout.writeln(
      'PASS: Dart/.NET interoperability, proxy bypass, certificate pin, pairing, focus metadata, interactive input, screenshot and WSS',
    );
  } on Object {
    stderr.writeln('FAIL: Dart/.NET transport interoperability');
    exitCode = 1;
  }
}
