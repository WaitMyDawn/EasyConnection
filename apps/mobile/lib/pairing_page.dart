import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'connection.dart';

typedef InvitationPairer = Future<DeviceProfile> Function(
  PairingInvitation invitation,
  void Function(String) onProgress,
);

class PairingPage extends StatefulWidget {
  final Future<void> Function(DeviceProfile) onPair;
  final String? error;
  final InvitationPairer? pairer;
  const PairingPage({super.key, required this.onPair, this.error, this.pairer});
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _link = TextEditingController();
  PairingInvitation? _invitation;
  bool _busy = false;
  String? _error;
  String _progress = '';
  List<EndpointFailure> _failures = [];

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  void _parse() {
    try {
      final invitation = _link.text.trim().isEmpty
          ? null
          : PairingInvitation.parse(_link.text);
      setState(() {
        _invitation = invitation;
        _error = null;
        _failures = [];
      });
    } on ApiException catch (error) {
      setState(() {
        _invitation = null;
        _error = error.message;
        _failures = [];
      });
    }
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      if (data?.text?.isNotEmpty != true) {
        setState(() => _error = '剪贴板没有文字，请先复制电脑端的连接信息。');
        return;
      }
      _link.text = data!.text!;
      _parse();
    } on Object {
      if (mounted) setState(() => _error = '暂时无法读取剪贴板，请长按输入框粘贴。');
    }
  }

  Future<void> _pair() async {
    if (_invitation == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _failures = [];
      _progress = '正在查找电脑…';
    });
    try {
      final pairer =
          widget.pairer ??
          (invitation, onProgress) =>
              DesktopClient.pairInvitation(invitation, onProgress: onProgress);
      final profile = await pairer(_invitation!, (message) {
        if (mounted) setState(() => _progress = message);
      });
      await widget.onPair(profile);
    } on ConnectionException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _failures = error.failures;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) setState(() => _error = '配对结果未确认，请在电脑重新复制信息后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 40),
              const Icon(Icons.devices, size: 64, color: Color(0xff95b7ff)),
              const SizedBox(height: 24),
              Text(
                '连接你的电脑',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text('电脑上点「复制手机连接信息」，在这里粘贴。', textAlign: TextAlign.center),
              const SizedBox(height: 28),
              TextField(
                controller: _link,
                enabled: !_busy,
                minLines: 2,
                maxLines: 3,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => _parse(),
                decoration: InputDecoration(
                  labelText: '电脑连接信息',
                  hintText: '粘贴自己电脑生成的整段信息',
                  suffixIcon: IconButton(
                    tooltip: '从剪贴板粘贴',
                    onPressed: _busy ? null : _paste,
                    icon: const Icon(Icons.content_paste),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_invitation != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.desktop_windows_outlined),
                    title: Text(_invitation!.hostName),
                    subtitle: Text(
                      '地址和配对码已自动导入${_invitation!.fallback.isEmpty ? '' : ' · 含外网备用地址'}',
                    ),
                    trailing: IconButton(
                      tooltip: '清空，换一台电脑',
                      onPressed: _busy
                          ? null
                          : () {
                              _link.clear();
                              _parse();
                            },
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_progress),
                ),
              if (_error != null || widget.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error ?? widget.error!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              FilledButton.icon(
                onPressed: _busy || _invitation == null ? null : _pair,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('连接此电脑'),
                ),
              ),
              if (_failures.isNotEmpty)
                ExpansionTile(
                  title: const Text('查看连接诊断'),
                  children: [
                    for (final failure in _failures)
                      ListTile(
                        dense: true,
                        title: Text(failure.description),
                        subtitle: Text(failure.endpoint),
                      ),
                  ],
                ),
              const SizedBox(height: 24),
              const Text(
                '首次配对后会记住电脑。更换网络时自动尝试导入的地址；跨网络需电脑有可达的公网或隧道地址。',
                style: TextStyle(color: Colors.white60),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
