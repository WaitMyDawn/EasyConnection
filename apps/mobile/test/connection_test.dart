import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:easy_connection/connection.dart';
import 'package:easy_connection/main.dart';
import 'package:easy_connection/pairing_page.dart';

import 'dart:convert';

class MemoryStore implements DeviceStore {
  @override
  Future<DeviceProfile?> load() async => null;
  @override
  Future<void> save(DeviceProfile profile) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  test(
    'direct endpoints accept IPv6 and reject credentials, HTTP and paths',
    () {
      expect(parseEndpoint('https://[2001:db8::5]:23456').host, '2001:db8::5');
      for (final value in [
        'http://host:1234',
        'https://user:password@host',
        'https://host/path',
        'https://host/?token=private',
      ]) {
        expect(() => parseEndpoint(value), throwsA(isA<ApiException>()));
      }
    },
  );
  test('pairing link validates pinned identity', () {
    final fingerprint = List.filled(64, 'a').join();
    final link = Uri(
      scheme: 'easyconnection',
      host: 'pair',
      queryParameters: {
        'endpoint': 'https://example.test:23456',
        'fingerprint': fingerprint,
        'code': '12345678',
      },
    ).toString();
    expect(parsePairingLink(link)['fingerprint'], fingerprint);
    expect(
      () => normalizeFingerprint('ignore-certificate-errors'),
      throwsA(isA<ApiException>()),
    );
    expect(requestId(), isNot(requestId()));
  });
  String encoded({
    List<String>? endpoints,
    String fallback = '',
    int version = 2,
    DateTime? expiry,
  }) =>
      'EC2:${base64Url.encode(utf8.encode(jsonEncode({
        'version': version,
        'hostName': 'Desk Ω',
        'endpoints': endpoints ?? ['https://192.0.2.10:23456', 'https://[2001:db8::4]:23456'],
        'fallback': fallback,
        'fingerprint': List.filled(64, 'a').join(),
        'code': '12345678',
        'expiresAt': (expiry ?? DateTime.now().add(const Duration(minutes: 5))).toUtc().toIso8601String(),
      }))).replaceAll('=', '')}';

  test('new invitation imports all addresses, fallback and expiry', () {
    final value = PairingInvitation.parse(
      encoded(fallback: 'https://relay.example.test:4433'),
    );
    expect(value.endpoints.length, 2);
    expect(value.fallback, 'https://relay.example.test:4433');
    expect(value.code, '12345678');
    expect(
      () => PairingInvitation.parse(encoded(expiry: DateTime(2000))),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => PairingInvitation.parse(encoded(version: 99)),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => PairingInvitation.parse(
        encoded(endpoints: ['https://name:test@example.test']),
      ),
      throwsA(isA<ApiException>()),
    );
  });
  test(
    'address probes skip unreachable interfaces and preserve fallback ordering',
    () async {
      final calls = <String>[];
      final found = await findReachableEndpoint(
        ['https://192.0.2.1', 'https://192.0.2.2'],
        'https://relay.example.test',
        'a' * 64,
        probe: (endpoint, _) async {
          calls.add(endpoint);
          if (endpoint.contains('192.0.2.1')) {
            throw const EndpointProbeException('timeout');
          }
        },
      );
      expect(found, 'https://192.0.2.2');
      expect(calls, isNot(contains('https://relay.example.test')));
      final fallback = await findReachableEndpoint(
        ['https://192.0.2.1'],
        'https://relay.example.test',
        'a' * 64,
        probe: (endpoint, _) async {
          if (endpoint.contains('192.0.2.1')) {
            throw const EndpointProbeException('refused');
          }
        },
      );
      expect(fallback, 'https://relay.example.test');
    },
  );
  test('unreachable network reports bounded, typed diagnostics', () async {
    try {
      await findReachableEndpoint(
        ['https://192.0.2.1'],
        '',
        'a' * 64,
        probe: (_, _) async => throw const EndpointProbeException('timeout'),
      );
      fail('Expected diagnostic failure');
    } on ConnectionException catch (error) {
      expect(error.failures.single.kind, 'timeout');
      expect(error.message, contains('校园网'));
      expect(error.message, isNot(contains('12345678')));
    }
  });
  test('saved legacy profiles remain compatible', () {
    final profile = DeviceProfile.fromJson({
      'endpoint': 'https://192.0.2.2',
      'fingerprint': 'a' * 64,
      'token': 'fixture-token',
      'deviceId': 'fixture',
      'hostName': 'Desk',
    });
    expect(profile.directEndpoints, ['https://192.0.2.2']);
  });
  testWidgets('first launch needs one invitation field', (tester) async {
    await tester.pumpWidget(EasyConnectionApp(store: MemoryStore()));
    await tester.pumpAndSettle();
    expect(find.text('连接你的电脑'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('证书 SHA-256 指纹'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '连接此电脑'))
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'pasted invitation enables one-click pairing without repeated fields',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PairingPage(
            onPair: (_) async {},
            pairer: (invitation, progress) async {
              calls++;
              expect(invitation.endpoints.length, 2);
              return DeviceProfile(
                endpoint: invitation.endpoints.first,
                fingerprint: invitation.fingerprint,
                token: 'fixture-token',
                deviceId: 'fixture',
                hostName: 'Desk',
              );
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), encoded());
      await tester.pumpAndSettle();
      expect(find.text('Desk Ω'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(FilledButton, '连接此电脑'));
      await tester.tap(find.widgetWithText(FilledButton, '连接此电脑'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
