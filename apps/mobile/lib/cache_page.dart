import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'connection.dart';

const phoneCacheChannel = MethodChannel('dev.easyconnection/cache');

String formatBytes(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';

class PhoneCachePage extends StatefulWidget {
  final Future<List<Json>> Function() inspect;
  final Future<String> Function() clear;
  const PhoneCachePage({super.key, required this.inspect, required this.clear});
  @override
  State<PhoneCachePage> createState() => _PhoneCachePageState();
}

class _PhoneCachePageState extends State<PhoneCachePage> {
  List<Json>? _items;
  String? _message;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final items = await widget.inspect();
      if (mounted) setState(() => _items = items);
    } on Object {
      if (mounted) setState(() => _message = '缓存用量读取失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      final message = await widget.clear();
      final items = await widget.inspect();
      if (mounted) {
        setState(() {
          _message = message;
          _items = items;
        });
      }
    } on Object {
      if (mounted) setState(() => _message = '部分缓存未能清理，请刷新用量后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('手机缓存'),
      actions: [
        IconButton(
          tooltip: '刷新用量',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('仅查看和清理本手机。电脑缓存请在电脑端管理。配对、预置流程和任务记录保留。'),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_message!),
          ),
        for (final item in _items ?? <Json>[])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['name'] as String,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${formatBytes((item['bytes'] as num).toInt())} · ${item['entries']} 项${item['clearable'] == false ? ' · 系统维护' : ''}',
                  ),
                  const SizedBox(height: 8),
                  SelectableText('位置：${item['location']}'),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy || _items == null ? null : _clear,
          icon: const Icon(Icons.cleaning_services),
          label: const Text('清理手机缓存'),
        ),
        const SizedBox(height: 8),
        const Text('截图数据和解码图像位于内存；临时文件位于上列目录。Android 运行代码缓存由系统维护，不在手动清理范围内。'),
      ],
    ),
  );
}
