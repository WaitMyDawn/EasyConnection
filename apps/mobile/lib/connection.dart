import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

typedef Json = Map<String, dynamic>;

Uri parseEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const ApiException('请输入 HTTPS 地址，支持域名、IPv4 和 [IPv6]:端口。');
  }
  return uri.replace(path: '');
}

String normalizeFingerprint(String value) {
  final fingerprint = value.replaceAll(RegExp(r'[:\s-]'), '').toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
    throw const ApiException('证书指纹应为电脑端显示的 64 位 SHA-256。');
  }
  return fingerprint;
}

class PairingInvitation {
  final String hostName, fingerprint, code, fallback;
  final List<String> endpoints;
  final DateTime? expiresAt;
  const PairingInvitation({
    required this.hostName,
    required this.endpoints,
    required this.fingerprint,
    required this.code,
    this.fallback = '',
    this.expiresAt,
  });

  void validate() {
    normalizeFingerprint(fingerprint);
    if (!RegExp(r'^\d{8}$').hasMatch(code)) {
      throw const ApiException('连接信息中的配对码无效，请重新从电脑复制。');
    }
    if (endpoints.length > 16 || (endpoints.isEmpty && fallback.isEmpty)) {
      throw const ApiException('连接信息缺少电脑地址。');
    }
    for (final endpoint in [...endpoints, if (fallback.isNotEmpty) fallback]) {
      parseEndpoint(endpoint);
    }
    if (expiresAt != null && !DateTime.now().isBefore(expiresAt!)) {
      throw const ApiException('连接信息已过期，请在电脑端重新复制。');
    }
  }

  factory PairingInvitation.parse(String value) {
    try {
      if (value.length > 16384) throw const FormatException();
      final text = value.trim().replaceAll(RegExp(r'\s+'), '');
      late PairingInvitation invitation;
      if (text.startsWith('EC2:')) {
        final json = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(text.substring(4)))),
        ) as Json;
        if (json['version'] != 2) throw const ApiException('连接信息版本不兼容，请更新手机端。');
        invitation = PairingInvitation(
          hostName: json['hostName'] as String,
          endpoints: (json['endpoints'] as List)
              .cast<String>()
              .map((e) => parseEndpoint(e).toString())
              .toSet()
              .toList(),
          fallback: (json['fallback'] as String? ?? '').isEmpty
              ? ''
              : parseEndpoint(json['fallback'] as String).toString(),
          fingerprint: normalizeFingerprint(json['fingerprint'] as String),
          code: json['code'] as String,
          expiresAt: DateTime.parse(json['expiresAt'] as String),
        );
      } else {
        final uri = Uri.parse(text);
        if (uri.scheme != 'easyconnection' || uri.host != 'pair') {
          throw const FormatException();
        }
        final parameters = uri.queryParameters;
        invitation = PairingInvitation(
          hostName: '我的电脑',
          endpoints: [parseEndpoint(parameters['endpoint'] ?? '').toString()],
          fingerprint: normalizeFingerprint(parameters['fingerprint'] ?? ''),
          code: parameters['code'] ?? '',
        );
      }
      invitation.validate();
      return invitation;
    } on ApiException {
      rethrow;
    } on Object {
      throw const ApiException('请粘贴电脑端完整复制的连接信息。');
    }
  }
}

Json parsePairingLink(String value) {
  final invitation = PairingInvitation.parse(value);
  return {
    'endpoint': invitation.endpoints.firstOrNull ?? invitation.fallback,
    'fingerprint': invitation.fingerprint,
    'code': invitation.code,
  };
}

class EndpointFailure {
  final String endpoint, kind;
  const EndpointFailure(this.endpoint, this.kind);
  String get description => switch (kind) {
    'dns' => '域名解析失败',
    'refused' => '端口拒绝连接',
    'timeout' => '连接超时',
    'certificate_mismatch' => '电脑证书不匹配',
    'certificate_time' => '证书或手机时间无效',
    'tls' => 'TLS 握手失败',
    'wrong_service' => '地址对应的服务不是兼容的电脑端',
    _ => '网络不可达',
  };
}

class ConnectionException extends ApiException {
  final List<EndpointFailure> failures;
  ConnectionException(this.failures)
    : super(
        '未连接到电脑，已尝试 ${failures.length} 个地址。'
        '${failures.any((f) => f.kind.startsWith('certificate')) ? '请重新复制电脑信息，并检查 TLS 连接是否被代理接管。' : '请检查电脑端防火墙；校园网可能限制设备互访，跨网络需公网或隧道地址。'}',
      );
}

typedef EndpointProbe = Future<void> Function(
  String endpoint,
  String fingerprint,
);
Future<String> findReachableEndpoint(
  List<String> direct,
  String fallback,
  String fingerprint, {
  EndpointProbe? probe,
}) async {
  final failures = <EndpointFailure>[];
  final candidates = direct
      .map((e) => parseEndpoint(e).toString())
      .toSet()
      .toList();
  final inspect = probe ?? probeHealth;
  // Probes carry no pairing code or bearer token and may run concurrently.
  for (var offset = 0; offset < candidates.length; offset += 3) {
    final batch = candidates.skip(offset).take(3).toList();
    final winner = Completer<String?>();
    var remaining = batch.length;
    for (final endpoint in batch) {
      () async {
        try {
          await inspect(endpoint, fingerprint);
          if (!winner.isCompleted) winner.complete(endpoint);
        } on EndpointProbeException catch (error) {
          failures.add(EndpointFailure(endpoint, error.kind));
        } on Object {
          failures.add(EndpointFailure(endpoint, 'network'));
        } finally {
          if (--remaining == 0 && !winner.isCompleted) winner.complete(null);
        }
      }();
    }
    final found = await winner.future;
    if (found != null) return found;
  }
  if (fallback.isNotEmpty &&
      !candidates.contains(parseEndpoint(fallback).toString())) {
    final endpoint = parseEndpoint(fallback).toString();
    try {
      await inspect(endpoint, fingerprint);
      return endpoint;
    } on EndpointProbeException catch (error) {
      failures.add(EndpointFailure(endpoint, error.kind));
    } on Object {
      failures.add(EndpointFailure(endpoint, 'network'));
    }
  }
  throw ConnectionException(failures);
}

class EndpointProbeException implements Exception {
  final String kind;
  const EndpointProbeException(this.kind);
}

Future<void> probeHealth(String endpoint, String fingerprint) async {
  String? certificateFailure;
  final uri = parseEndpoint(endpoint);
  final client = DesktopClient.pinnedClient(
    fingerprint,
    onCertificateFailure: (kind) => certificateFailure = kind,
  );
  try {
    if (InternetAddress.tryParse(uri.host) == null) {
      try {
        await InternetAddress.lookup(uri.host)
            .timeout(const Duration(seconds: 3));
      } on TimeoutException {
        throw const EndpointProbeException('timeout');
      } on SocketException {
        throw const EndpointProbeException('dns');
      }
    }
    await (() async {
      final request = await client.getUrl(uri.resolve('/health'));
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != 200) {
        throw const EndpointProbeException('wrong_service');
      }
      final content = BytesBuilder();
      await for (final chunk in response) {
        content.add(chunk);
        if (content.length > 4096) {
          throw const EndpointProbeException('wrong_service');
        }
      }
      final body = jsonDecode(utf8.decode(content.takeBytes())) as Json;
      if (body['product'] != 'EasyConnection' || body['protocolVersion'] != 1) {
        throw const EndpointProbeException('wrong_service');
      }
    })().timeout(const Duration(seconds: 4));
  } on EndpointProbeException {
    rethrow;
  } on TimeoutException {
    throw const EndpointProbeException('timeout');
  } on HandshakeException {
    throw EndpointProbeException(certificateFailure ?? 'tls');
  } on SocketException catch (error) {
    throw EndpointProbeException(
      [61, 111, 10061].contains(error.osError?.errorCode)
          ? 'refused'
          : 'network',
    );
  } on Object {
    throw const EndpointProbeException('wrong_service');
  } finally {
    client.close(force: true);
  }
}

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
  @override
  String toString() => message;
}

class DeviceProfile {
  final String endpoint, fallback, fingerprint, token, deviceId, hostName;
  final List<String> candidateEndpoints;
  List<String> get directEndpoints =>
      {endpoint, ...candidateEndpoints}.where((e) => e != fallback).toList();
  const DeviceProfile({
    required this.endpoint,
    required this.fingerprint,
    required this.token,
    required this.deviceId,
    required this.hostName,
    this.fallback = '',
    this.candidateEndpoints = const [],
  });
  Json toJson() => {
    'endpoint': endpoint,
    'fallback': fallback,
    'candidateEndpoints': candidateEndpoints,
    'fingerprint': fingerprint,
    'token': token,
    'deviceId': deviceId,
    'hostName': hostName,
  };
  factory DeviceProfile.fromJson(Json json) => DeviceProfile(
    endpoint: json['endpoint'] as String,
    fallback: json['fallback'] as String? ?? '',
    candidateEndpoints: (json['candidateEndpoints'] as List? ?? [])
        .cast<String>(),
    fingerprint: json['fingerprint'] as String,
    token: json['token'] as String,
    deviceId: json['deviceId'] as String,
    hostName: json['hostName'] as String,
  );
  DeviceProfile withAddresses(String direct, String tunnel) => DeviceProfile(
    endpoint: parseEndpoint(direct).toString(),
    fallback: tunnel.trim().isEmpty ? '' : parseEndpoint(tunnel).toString(),
    candidateEndpoints: candidateEndpoints,
    fingerprint: fingerprint,
    token: token,
    deviceId: deviceId,
    hostName: hostName,
  );
}

abstract class DeviceStore {
  Future<DeviceProfile?> load();
  Future<void> save(DeviceProfile profile);
  Future<void> clear();
}

String requestId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class DesktopClient {
  DeviceProfile profile;
  HttpClient? _client;
  Uri? activeEndpoint;
  bool get usingTunnel =>
      activeEndpoint != null && activeEndpoint.toString() == profile.fallback;
  DesktopClient(this.profile);

  static HttpClient pinnedClient(
    String fingerprint, {
    void Function(String)? onCertificateFailure,
  }) {
    final expected = normalizeFingerprint(fingerprint);
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.connectionTimeout = const Duration(seconds: 3);
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (certificate, host, port) {
      final now = DateTime.now();
      if (sha256.convert(certificate.der).toString() != expected) {
        onCertificateFailure?.call('certificate_mismatch');
        return false;
      }
      if (now.isBefore(certificate.startValidity) ||
          now.isAfter(certificate.endValidity)) {
        onCertificateFailure?.call('certificate_time');
        return false;
      }
      return true;
    };
    return client;
  }

  Future<Json> connect() async {
    close();
    final selected = await findReachableEndpoint(
      profile.directEndpoints,
      profile.fallback,
      profile.fingerprint,
    );
    _client = pinnedClient(profile.fingerprint);
    activeEndpoint = parseEndpoint(selected);
    try {
      final status = await get('/api/v1/status') as Json;
      if (status['protocolVersion'] != 1) {
        throw const ApiException('电脑端协议版本不兼容。');
      }
      return status;
    } on Object {
      close();
      rethrow;
    }
  }

  static Future<DeviceProfile> pair(
    String endpoint,
    String fallback,
    String fingerprint,
    String code,
    String name,
  ) => pairInvitation(
    PairingInvitation(
      hostName: '电脑',
      endpoints: [parseEndpoint(endpoint).toString()],
      fallback: fallback.isEmpty ? '' : parseEndpoint(fallback).toString(),
      fingerprint: normalizeFingerprint(fingerprint),
      code: code,
    ),
    name: name,
  );

  static Future<DeviceProfile> pairInvitation(
    PairingInvitation invitation, {
    String? name,
    void Function(String)? onProgress,
  }) async {
    invitation.validate();
    onProgress?.call('正在尝试电脑提供的地址…');
    final selected = await findReachableEndpoint(
      invitation.endpoints,
      invitation.fallback,
      invitation.fingerprint,
    );
    final temporary = DesktopClient(
      DeviceProfile(
        endpoint: invitation.endpoints.firstOrNull ?? invitation.fallback,
        candidateEndpoints: invitation.endpoints,
        fallback: invitation.fallback,
        fingerprint: invitation.fingerprint,
        token: '',
        deviceId: '',
        hostName: '',
      ),
    );
    temporary._client = pinnedClient(invitation.fingerprint);
    temporary.activeEndpoint = parseEndpoint(selected);
    try {
      invitation.validate();
      onProgress?.call('已找到电脑，正在完成配对…');
      // Only health probes are retried; replaying a pairing POST could consume a second one-time grant.
      final result = await temporary.post('/api/v1/pair', {
        'code': invitation.code,
        'deviceName': name ?? '${Platform.operatingSystem} 手机',
      }) as Json;
      return DeviceProfile(
        endpoint: temporary.profile.endpoint,
        candidateEndpoints: invitation.endpoints,
        fallback: invitation.fallback,
        fingerprint: invitation.fingerprint,
        token: result['token'] as String,
        deviceId: result['deviceId'] as String,
        hostName: result['hostName'] as String,
      );
    } on ApiException {
      rethrow;
    } on Object {
      throw const ApiException('配对结果未确认，请在电脑端重新复制连接信息后再试。');
    } finally {
      temporary.close();
    }
  }

  Future<dynamic> get(String path) => _request('GET', path);
  Future<dynamic> post(String path, Json body) => _request('POST', path, body);
  Future<dynamic> put(String path, Json body) => _request('PUT', path, body);
  Future<dynamic> delete(String path) => _request('DELETE', path);
  Future<Uint8List> image(String id) async =>
      await _request('GET', '/api/v1/snapshots/$id/image', null, true)
          as Uint8List;
  Future<dynamic> _request(
    String method,
    String path, [
    Json? body,
    bool binary = false,
  ]) async {
    if (_client == null || activeEndpoint == null) {
      throw const ApiException('尚未连接电脑。');
    }
    final request = await _client!
        .openUrl(method, activeEndpoint!.resolve(path))
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    if (profile.token.isNotEmpty) {
      request.headers.set('Authorization', 'Bearer ${profile.token}');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.add(chunk);
      if (bytes.length > 12 * 1024 * 1024) {
        throw const ApiException('返回内容超过大小限制。');
      }
    }
    final data = bytes.takeBytes();
    if (response.statusCode == 401) throw const ApiException('设备授权已失效，请重新配对。');
    if (response.statusCode >= 300) {
      String message = '请求失败（${response.statusCode}）。';
      try {
        message =
            (jsonDecode(utf8.decode(data)) as Json)['message'] as String? ??
            message;
      } on Object {
        /* Error bodies may originate from a tunnel rather than the host. */
      }
      throw ApiException(message);
    }
    if (binary) return data;
    return data.isEmpty ? null : jsonDecode(utf8.decode(data));
  }

  Future<Json> action(Json action) async => await post('/api/v1/actions', {
    'requestId': requestId(),
    'action': action,
  }) as Json;
  Future<Json> waitTask(String id) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final result = await get('/api/v1/tasks/$id') as Json;
      if (!['queued', 'running'].contains(result['state'])) return result;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw const ApiException('任务仍在执行。请在任务页查询结果；不要重复提交发送类操作。');
  }

  Future<WebSocket> live(String? displayId) async {
    if (activeEndpoint == null) throw const ApiException('尚未连接电脑。');
    final uri = activeEndpoint!.replace(
      scheme: 'wss',
      path: '/api/v1/live',
      queryParameters: displayId == null ? null : {'displayId': displayId},
    );
    return WebSocket.connect(
      uri.toString(),
      customClient: _client,
      headers: {'Authorization': 'Bearer ${profile.token}'},
    ).timeout(const Duration(seconds: 10));
  }

  void close() {
    _client?.close(force: true);
    _client = null;
    activeEndpoint = null;
  }
}
