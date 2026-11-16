import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:material_ui/material_ui.dart';

import 'connection.dart';
import 'credential_store.dart';
import 'pairing_page.dart';
import 'connection_settings.dart';
import 'flow_editor.dart';
import 'remote_desktop.dart';
import 'cache_page.dart';
import 'focused_input.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'EasyConnection',
    ], await rootBundle.loadString('assets/licenses/LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'Android runtime notices',
    ], await rootBundle.loadString('assets/licenses/THIRD-PARTY-NOTICES.txt'));
  });
  PaintingBinding.instance.imageCache.maximumSize = 16;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 * 1024 * 1024;
  runApp(EasyConnectionApp(store: SecureDeviceStore()));
}

class EasyConnectionApp extends StatelessWidget {
  final DeviceStore store;
  const EasyConnectionApp({super.key, required this.store});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EasyConnection',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff6f9eff),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff10141d),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
      ),
      cardTheme: const CardThemeData(margin: EdgeInsets.symmetric(vertical: 6)),
    ),
    home: Workspace(store: store),
  );
}

class Workspace extends StatefulWidget {
  final DeviceStore store;
  const Workspace({super.key, required this.store});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  DeviceProfile? _profile;
  DesktopClient? _api;
  Json? _status;
  final _desktopState = RemoteDesktopController();
  Json? get _snapshot => _desktopState.snapshot;
  Uint8List? get _image => _desktopState.image;
  bool _cursorPolling = false, _inputSheetOpen = false;
  List<Json> _windows = [], _flows = [], _tasks = [], _apps = [];
  String? _displayId;
  String? _error;
  bool _loading = true, _busy = false, _connected = false;
  int _tab = 0;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _liveSubscription;
  Timer? _poll;
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  Future<void> _restore() async {
    try {
      _profile = await widget.store.load();
    } on Object {
      _error = '无法读取设备凭据，请重新配对。';
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (_profile != null) await _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopLive();
    _poll?.cancel();
    _api?.close();
    _text.dispose();
    _desktopState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopLive();
      _poll?.cancel();
    } else if (_profile != null && !_busy) {
      _connect();
    }
  }

  void _message(Object error) {
    if (!mounted) return;
    _desktopState.error = error is ApiException
        ? error.message
        : '网络或系统操作失败，请检查连接。';
    _desktopState.changed();
    setState(
      () => _error = error is ApiException
          ? error.message
          : '连接或操作失败；请核对电脑当前状态后再操作，避免重复输入。',
    );
  }

  Future<void> _guard(Future<void> Function() work) async {
    if (_busy) return;
    _desktopState
      ..busy = true
      ..error = null;
    _desktopState.changed();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on Object catch (error) {
      _message(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _desktopState.busy = false;
        _desktopState.changed();
      }
    }
  }

  Future<void> _connect() => _guard(() async {
    await _stopLive();
    _poll?.cancel();
    _api?.close();
    if (mounted) setState(() => _connected = false);
    final client = DesktopClient(_profile!);
    _api = client;
    final status = await client.connect();
    if (!(status['capabilities'] as List? ?? []).contains('typeFocusedText')) {
      throw const ApiException('请先将电脑端更新至 0.4.0，再使用焦点输入与实时控制。');
    }
    if (!mounted) {
      client.close();
      return;
    }
    setState(() {
      _status = status;
      _connected = true;
    });
    _desktopState.pointerSupported = (status['capabilities'] as List? ?? [])
        .contains('movePointer');
    _desktopState.changed();
    await _refresh();
    _desktopState.focus = null;
    try {
      await _refreshFocus();
    } on Object {
      // A temporarily unavailable foreground window must not block pairing or desktop viewing.
    }
    if (_tab == 1 && _desktopState.mode == DesktopMode.realtime) {
      await _startLive();
    }
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_tab == 1 && !_busy) _refreshCursor();
      if (_tab == 2 && !_busy) {
        _refreshTasks().catchError((Object error) => _message(error));
      }
    });
  });
  Future<void> _refresh() async {
    final api = _api!;
    final results = await Future.wait([
      api.get('/api/v1/windows'),
      api.get('/api/v1/flows'),
      api.get('/api/v1/tasks'),
      api.get('/api/v1/apps'),
    ]);
    if (!mounted) return;
    setState(() {
      _windows = (results[0] as List).cast<Json>();
      _flows = (results[1] as List).cast<Json>();
      _tasks = (results[2] as List).cast<Json>();
      _apps = (results[3] as List).cast<Json>();
    });
  }

  Future<void> _refreshTasks() async {
    final tasks = (await _api!.get('/api/v1/tasks') as List).cast<Json>();
    if (mounted) setState(() => _tasks = tasks);
  }

  Future<void> _capture() async {
    final epoch = _desktopState.generation;
    final metadata = await _api!.post('/api/v1/snapshots', {
      'type': 'screenshot',
      'displayId': _displayId,
    }) as Json;
    final image = await _api!.image(metadata['id'] as String);
    if (mounted && epoch == _desktopState.generation) {
      _desktopState.replace(metadata, image);
    }
  }

  Future<void> _refreshFocus() async {
    final focus = await _api!.get('/api/v1/focus') as Json;
    if (mounted) {
      _desktopState.focus = focus;
      _desktopState.changed();
    }
  }

  Future<void> _perform(Json action) async {
    var openInput = false;
    await _guard(() async {
      final reference = _snapshot;
      final result = await _api!.post('/api/v1/interactions', {
        'requestId': requestId(),
        'action': action,
      }) as Json;
      if (result['focus'] != null) {
        _desktopState.focus = result['focus'] as Json;
      }
      if (reference != null && result['cursor'] != null) {
        _desktopState.cursor({
          'displayId': reference['displayId'],
          'layoutId': reference['layoutId'],
          'cursor': result['cursor'],
        });
      }
      _desktopState.changed();
      if (_socket == null && action['type'] != 'movePointer') await _capture();
      openInput =
          (action['type'] == 'click' || action['type'] == 'clickPointer') &&
          action['button'] != 'right' &&
          _desktopState.focus?['editable'] == true;
    });
    if (openInput && mounted) await _openInput();
  }

  Future<void> _sendText(String text, String focusId) => _guard(() async {
    final result = await _api!.post('/api/v1/interactions', {
      'requestId': requestId(),
      'action': {'type': 'typeFocusedText', 'text': text, 'focusId': focusId},
    }) as Json;
    if (result['focus'] != null) _desktopState.focus = result['focus'] as Json;
    _text.clear();
    if (_socket == null) await _capture();
  });
  Future<void> _focusedKey(List<String> keys) async {
    final focus = _desktopState.focus;
    if (focus == null) {
      await _guard(_refreshFocus);
      return;
    }
    await _perform({
      'type': 'focusedKeyChord',
      'keys': keys,
      'focusId': focus['id'],
    });
  }

  Future<void> _openInput() async {
    if (_inputSheetOpen || !mounted) return;
    if (_desktopState.focus == null) await _guard(_refreshFocus);
    final focus = _desktopState.focus;
    if (!mounted || focus == null) return;
    _inputSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => FocusedInputSheet(
          controller: _desktopState,
          target: focus,
          text: _text,
          onSubmit: _sendText,
          onKey: (keys, id) => _perform({
            'type': 'focusedKeyChord',
            'keys': keys,
            'focusId': id,
          }),
        ),
      );
    } finally {
      _inputSheetOpen = false;
    }
  }

  Future<void> _setMode(DesktopMode mode) => _guard(() async {
    _desktopState.mode = mode;
    _desktopState.changed();
    if (mode == DesktopMode.realtime) {
      await _startLive();
    } else {
      await _stopLive();
      await _capture();
    }
  });
  Future<void> _startLive() async {
    await _stopLive();
    final socket = await _api!.live(_displayId);
    if (!mounted) {
      socket.close();
      return;
    }
    Json? next;
    final epoch = _desktopState.generation;
    _desktopState.live = true;
    _desktopState.changed();
    setState(() => _socket = socket);
    _liveSubscription = socket.listen(
      (data) {
        if (!mounted ||
            epoch != _desktopState.generation ||
            !identical(_socket, socket)) {
          return;
        }
        if (data is String) {
          next = jsonDecode(data) as Json;
        } else if (data is List<int> &&
            next != null &&
            data.length <= 12 * 1024 * 1024) {
          _desktopState.replace(next!, Uint8List.fromList(data));
        }
      },
      onError: (Object error) {
        if (identical(_socket, socket)) {
          _stopLive();
          _message(error);
        }
      },
      onDone: () {
        if (mounted && identical(_socket, socket)) {
          setState(() => _socket = null);
          _desktopState.live = false;
          _desktopState.changed();
        }
      },
    );
  }

  Future<void> _stopLive() async {
    final socket = _socket;
    _socket = null;
    _desktopState.live = false;
    _desktopState.changed();
    await _liveSubscription?.cancel();
    _liveSubscription = null;
    try {
      await socket?.close().timeout(const Duration(seconds: 2));
    } on Object {
      // An unavailable peer must not block navigation or reconnecting to another address.
    }
    if (mounted) setState(() {});
  }

  Future<void> _editFlow([Json? flow]) async {
    final edited = await Navigator.of(context).push<Json>(
      MaterialPageRoute(
        builder: (_) => FlowEditor(
          flow: flow,
          windows: _windows,
          apps: _apps,
          inspect: (id) async => await _api!.get(
            '/api/v1/windows/${Uri.encodeComponent(id)}/elements',
          ) as Json,
        ),
      ),
    );
    if (edited != null) {
      await _guard(() async {
        if (edited['_delete'] == true) {
          await _api!.delete('/api/v1/flows/${edited['id']}');
        } else {
          await _api!.put('/api/v1/flows/${edited['id']}', edited);
        }
        await _refresh();
      });
    }
  }

  Future<void> _runFlow(Json flow) async {
    final parameters = (flow['parameters'] as List? ?? []).cast<Json>();
    final controllers = {
      for (final p in parameters) p['name'] as String: TextEditingController(),
    };
    var proceed = true;
    if (parameters.isNotEmpty) {
      proceed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(flow['name'] as String),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final parameter in parameters)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TextField(
                          controller: controllers[parameter['name']],
                          decoration: InputDecoration(
                            labelText: parameter['label'] as String,
                          ),
                          maxLines: 3,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('执行'),
                ),
              ],
            ),
          ) ??
          false;
    }
    final arguments = {
      for (final entry in controllers.entries) entry.key: entry.value.text,
    };
    for (final controller in controllers.values) {
      controller.dispose();
    }
    if (!proceed) return;
    await _guard(() async {
      await _api!.post('/api/v1/flows/${flow['id']}/run', {
        'requestId': requestId(),
        'arguments': arguments,
      });
      await _refreshTasks();
      if (mounted) setState(() => _tab = 2);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_profile == null) {
      return PairingPage(
        error: _error,
        onPair: (profile) async {
          await widget.store.save(profile);
          if (!mounted) return;
          setState(() => _profile = profile);
          await _connect();
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'EasyConnection',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              '${_profile!.hostName} · ${_connected ? (_api!.usingTunnel ? '备用隧道' : '直连地址') : '未连接'}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _connect,
            tooltip: '重新连接',
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            Expanded(
              child: !_connected && _tab != 3
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.desktop_access_disabled_outlined,
                              size: 56,
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              '电脑尚未连接',
                              style: TextStyle(fontSize: 22),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '检查电脑端是否运行，或在连接页填写备用隧道地址。',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            FilledButton(
                              onPressed: _busy ? null : _connect,
                              child: const Text('重新连接'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : switch (_tab) {
                      0 => _shortcuts(),
                      1 => _desktop(),
                      2 => _taskList(),
                      _ => _connection(),
                    },
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) async {
          if (index != 1) await _stopLive();
          if (!mounted) return;
          setState(() => _tab = index);
          if (_connected && index == 1) {
            if (_desktopState.mode == DesktopMode.realtime) {
              await _guard(_startLive);
            } else if (_image == null) {
              await _guard(_capture);
            }
          }
          if (_connected && index == 2) {
            _refreshTasks().catchError((Object error) => _message(error));
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bolt_outlined), label: '快捷'),
          NavigationDestination(
            icon: Icon(Icons.desktop_windows_outlined),
            label: '桌面',
          ),
          NavigationDestination(icon: Icon(Icons.task_alt), label: '任务'),
          NavigationDestination(icon: Icon(Icons.link), label: '连接'),
        ],
      ),
    );
  }

  Widget _shortcuts() => RefreshIndicator(
    onRefresh: () => _guard(_refresh),
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('随手操作你的电脑', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('按需截图，或一键执行已保存的操作流程。'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _guard(() async {
                  await _stopLive();
                  _desktopState.mode = DesktopMode.step;
                  await _capture();
                  if (mounted) setState(() => _tab = 1);
                }),
          icon: const Icon(Icons.screenshot_monitor),
          label: const Padding(
            padding: EdgeInsets.all(14),
            child: Text('获取当前桌面'),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('预置流程', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            TextButton.icon(
              onPressed: _busy ? null : _editFlow,
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            ),
          ],
        ),
        for (final flow in _flows)
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: const Icon(Icons.play_circle_outline),
              title: Text(flow['name'] as String),
              subtitle: Text(flow['description'] as String? ?? ''),
              onTap: _busy ? null : () => _runFlow(flow),
              trailing: IconButton(
                tooltip: '编辑流程',
                onPressed: _busy ? null : () => _editFlow(flow),
                icon: const Icon(Icons.edit_outlined),
              ),
            ),
          ),
        const SizedBox(height: 16),
        const Text(
          '流程在电脑本地执行。手机离开后，可重新连接查看任务结果。',
          style: TextStyle(color: Colors.white60),
        ),
      ],
    ),
  );

  Widget _desktop() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _displayId,
              decoration: const InputDecoration(labelText: '显示器'),
              items: [
                const DropdownMenuItem(value: null, child: Text('主显示器')),
                for (final d
                    in (_status?['displays'] as List? ?? []).cast<Json>())
                  DropdownMenuItem(
                    value: d['id'] as String,
                    child: Text(
                      '${d['name']} · ${d['width']}×${d['height']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) async {
                      await _stopLive();
                      setState(() {
                        _displayId = value;
                        _desktopState.clear();
                      });
                      if (_desktopState.mode == DesktopMode.realtime) {
                        await _guard(_startLive);
                      } else {
                        await _guard(_capture);
                      }
                    },
            ),
          ),
          IconButton(
            tooltip: '刷新截图',
            onPressed: _busy ? null : () => _guard(_capture),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 260,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: RemoteViewport(controller: _desktopState, onAction: _perform),
        ),
      ),
      Row(
        children: [
          Expanded(
            child: TextButton.icon(
              onPressed: _busy ? null : _openLandscape,
              icon: const Icon(Icons.screen_rotation),
              label: const Text('横屏全屏'),
            ),
          ),
        ],
      ),
      AnimatedBuilder(
        animation: _desktopState,
        builder: (context, _) => Column(
          children: [
            SegmentedButton<DesktopMode>(
              segments: const [
                ButtonSegment(
                  value: DesktopMode.realtime,
                  icon: Icon(Icons.live_tv),
                  label: Text('实时控制'),
                ),
                ButtonSegment(
                  value: DesktopMode.step,
                  icon: Icon(Icons.screenshot_monitor),
                  label: Text('单步查看'),
                ),
              ],
              selected: {_desktopState.mode},
              onSelectionChanged: _busy
                  ? null
                  : (modes) => _setMode(modes.first),
            ),
            Text(
              _desktopState.mode == DesktopMode.realtime
                  ? (_desktopState.live
                        ? '画面自动同步，点击和按键即时执行'
                        : '实时控制未连接，可重新选择模式')
                  : '每次操作后更新一张截图，不持续传输画面',
            ),
            if (_desktopState.mode == DesktopMode.realtime &&
                !_desktopState.live)
              TextButton(
                onPressed: _busy ? null : () => _guard(_startLive),
                child: const Text('重新连接画面'),
              ),
          ],
        ),
      ),
      PointerControls(
        controller: _desktopState,
        onMove: _nudge,
        onClick: _pointerClick,
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final direction in [1, -1])
            OutlinedButton.icon(
              onPressed: _busy || _snapshot == null
                  ? null
                  : () => _perform({
                      'type': 'scroll',
                      'snapshotId': _snapshot!['id'],
                      'x': 0.5,
                      'y': 0.5,
                      'wheelDelta': direction * 360,
                    }),
              icon: Icon(
                direction == 1
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
              ),
              label: Text(direction == 1 ? '向上滚动' : '向下滚动'),
            ),
        ],
      ),
      const SizedBox(height: 16),
      AnimatedBuilder(
        animation: _desktopState,
        builder: (context, _) => ListTile(
          leading: const Icon(Icons.keyboard),
          title: Text(
            _desktopState.focus?['description'] as String? ?? '点击电脑画面中的输入位置',
          ),
          subtitle: const Text('点击输入框后自动打开键盘，也可手动打开输入面板'),
          trailing: FilledButton(
            onPressed: _busy ? null : _openInput,
            child: const Text('输入文字'),
          ),
        ),
      ),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final entry in <String, List<String>>{
            'Enter': ['ENTER'],
            'Esc': ['ESC'],
            'Tab': ['TAB'],
            'Ctrl+A': ['CTRL', 'A'],
            'Ctrl+C': ['CTRL', 'C'],
            'Ctrl+V': ['CTRL', 'V'],
            '↑': ['UP'],
            '↓': ['DOWN'],
            '←': ['LEFT'],
            '→': ['RIGHT'],
          }.entries)
            OutlinedButton(
              onPressed: _busy ? null : () => _focusedKey(entry.value),
              child: Text(entry.key),
            ),
        ],
      ),
      const Text('文字中的换行按 Shift+Enter 输入；Enter 按键单独执行。'),
    ],
  );
  Future<void> _refreshCursor() async {
    if (_cursorPolling ||
        !_desktopState.pointerSupported ||
        _snapshot == null) {
      return;
    }
    _cursorPolling = true;
    final frame = _snapshot!;
    try {
      final state = await _api!.get(
        '/api/v1/pointer?displayId=${Uri.encodeQueryComponent(frame['displayId'] as String)}',
      ) as Json;
      if (mounted && _snapshot?['id'] == frame['id']) {
        _desktopState.cursor(state);
      }
    } on Object {
      // Cursor telemetry is optional; an unavailable peer must not interrupt an active gesture.
    } finally {
      _cursorPolling = false;
    }
  }

  Future<void> _pointer(Json input) async {
    if (_busy) return;
    if (_snapshot == null ||
        DateTime.now()
                .difference(DateTime.parse(_snapshot!['capturedAt'] as String))
                .inSeconds >=
            5) {
      await _guard(_capture);
    }
    final reference = _snapshot;
    if (reference == null) return;
    await _perform({...input, 'snapshotId': reference['id']});
  }

  Future<void> _nudge(int dx, int dy) =>
      _pointer({'type': 'movePointer', 'deltaX': dx, 'deltaY': dy});
  Future<void> _pointerClick(String button) =>
      _pointer({'type': 'clickPointer', 'button': button});
  Future<void> _openLandscape() async {
    if (_image == null) await _guard(_capture);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LandscapeDesktopPage(
          controller: _desktopState,
          onAction: _perform,
          onMove: _nudge,
          onClick: _pointerClick,
          onRefresh: () => _guard(_capture),
          onMode: _setMode,
          onInput: _openInput,
        ),
      ),
    );
  }

  Future<List<Json>> _phoneCacheUsage() async {
    final disk = await phoneCacheChannel.invokeMapMethod<String, dynamic>(
      'inspect',
    );
    final cache = PaintingBinding.instance.imageCache;
    return [
      {
        'name': '当前截图数据',
        'bytes': _image?.length ?? 0,
        'entries': _image == null ? 0 : 1,
        'location': '手机进程内存（不写入磁盘）',
        'clearable': true,
      },
      {
        'name': '图片解码缓存',
        'bytes': cache.currentSizeBytes,
        'entries': cache.currentSize,
        'location': '手机进程内存 / Flutter ImageCache',
        'clearable': true,
      },
      ...((disk?['items'] as List?) ?? []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    ];
  }

  Future<String> _clearCache() async {
    if (_busy) return '操作尚未结束，请稍后清理。';
    setState(() => _busy = true);
    _desktopState.busy = true;
    _desktopState.changed();
    try {
      await _stopLive();
      _desktopState.clear();
      if (mounted) await WidgetsBinding.instance.endOfFrame;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final result = await phoneCacheChannel.invokeMapMethod<String, dynamic>(
        'clear',
      );
      return (result?['skipped'] as int? ?? 0) > 0
          ? '手机内存图片已清理；部分占用中的临时文件未能删除，请刷新用量后重试。'
          : '手机截图、解码图片和临时文件已清理，电脑缓存未改动。';
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _desktopState.busy = false;
        _desktopState.changed();
      }
    }
  }

  Future<void> _openCache() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          PhoneCachePage(inspect: _phoneCacheUsage, clear: _clearCache),
    ),
  );

  Widget _taskList() => RefreshIndicator(
    onRefresh: () => _guard(_refreshTasks),
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('任务记录', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        if (_tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('暂无任务。执行动作或预置流程后将在这里显示。'),
          ),
        for (final task in _tasks)
          Card(
            child: ExpansionTile(
              title: Text(task['flowName'] as String),
              subtitle: Text(
                '${_stateName(task['state'] as String)} · ${DateTime.parse(task['createdAt'] as String).toLocal().toString().split('.').first}',
              ),
              leading: Icon(
                task['state'] == 'succeeded'
                    ? Icons.check_circle_outline
                    : task['state'] == 'failed'
                    ? Icons.error_outline
                    : Icons.pending_outlined,
              ),
              children: [
                if (task['error'] != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(task['error'] as String),
                  ),
                for (final step in (task['steps'] as List).cast<Json>())
                  ListTile(
                    dense: true,
                    title: Text(
                      '${(step['index'] as num) + 1}. ${step['type']} · ${_stateName(step['state'] as String)}',
                    ),
                    subtitle: step['message'] == null
                        ? null
                        : Text(step['message'] as String),
                    trailing: step['snapshot'] == null
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.image_outlined),
                            onPressed: () => _guard(() async {
                              final metadata = step['snapshot'] as Json;
                              final image = await _api!.image(
                                metadata['id'] as String,
                              );
                              if (mounted) {
                                setState(() {
                                  _desktopState.replace(metadata, image);
                                  _desktopState.mode = DesktopMode.step;
                                  _tab = 1;
                                });
                              }
                            }),
                          ),
                  ),
                if (['queued', 'running'].contains(task['state']))
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _guard(() async {
                            await _api!.post(
                              '/api/v1/tasks/${task['id']}/cancel',
                              {},
                            );
                            await _refreshTasks();
                          }),
                    child: const Text('取消后续步骤'),
                  ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _connection() => ConnectionSettings(
    profile: _profile!,
    busy: _busy,
    onOpenCache: _openCache,
    onSave: (profile) async {
      await widget.store.save(profile);
      _profile = profile;
      await _connect();
    },
    onForget: () async {
      await _stopLive();
      _poll?.cancel();
      _api?.close();
      await widget.store.clear();
      if (mounted) {
        setState(() {
          _profile = null;
          _connected = false;
          _error = null;
          _desktopState.clear();
          _desktopState.focus = null;
          _tab = 0;
        });
      }
    },
  );
}

String _stateName(String state) =>
    const {
      'queued': '排队中',
      'running': '执行中',
      'succeeded': '成功',
      'failed': '失败',
      'cancelled': '已取消',
      'unknown': '结果待检查',
    }[state] ??
    state;
