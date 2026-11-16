import 'package:material_ui/material_ui.dart';

import 'connection.dart';

class ConnectionSettings extends StatefulWidget {
  final DeviceProfile profile;
  final bool busy;
  final Future<void> Function(DeviceProfile) onSave;
  final Future<void> Function() onForget;
  final Future<void> Function()? onOpenCache;
  const ConnectionSettings({
    super.key,
    required this.profile,
    required this.busy,
    required this.onSave,
    required this.onForget,
    this.onOpenCache,
  });
  @override
  State<ConnectionSettings> createState() => _ConnectionSettingsState();
}

class _ConnectionSettingsState extends State<ConnectionSettings> {
  final _invitation = TextEditingController();
  late final _direct = TextEditingController(text: widget.profile.endpoint);
  late final _fallback = TextEditingController(text: widget.profile.fallback);
  String? _error;
  @override
  void dispose() {
    _invitation.dispose();
    _direct.dispose();
    _fallback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        widget.profile.hostName,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _invitation,
        minLines: 2,
        maxLines: 3,
        decoration: const InputDecoration(labelText: '粘贴电脑的新连接信息'),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: widget.busy
            ? null
            : () async {
                try {
                  final invitation = PairingInvitation.parse(_invitation.text);
                  if (invitation.fingerprint !=
                      normalizeFingerprint(widget.profile.fingerprint)) {
                    throw const ApiException('这段信息属于另一台电脑，请先移除当前电脑再配对。');
                  }
                  final updated = DeviceProfile(
                    endpoint:
                        invitation.endpoints.firstOrNull ?? invitation.fallback,
                    candidateEndpoints: invitation.endpoints,
                    fallback: invitation.fallback,
                    fingerprint: widget.profile.fingerprint,
                    token: widget.profile.token,
                    deviceId: widget.profile.deviceId,
                    hostName: widget.profile.hostName,
                  );
                  _direct.text = updated.endpoint;
                  _fallback.text = updated.fallback;
                  await widget.onSave(updated);
                } on Object catch (error) {
                  if (mounted) {
                    setState(
                      () => _error = error is ApiException
                          ? error.message
                          : '更新失败，请检查连接后重试。',
                    );
                  }
                }
              },
        icon: const Icon(Icons.sync),
        label: const Text('更新连接并重连'),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.orangeAccent),
          ),
        ),
      const SizedBox(height: 16),
      ExpansionTile(
        title: const Text('高级连接设置'),
        children: [
          TextField(
            controller: _direct,
            decoration: const InputDecoration(labelText: '优先连接地址'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _fallback,
            decoration: const InputDecoration(labelText: '外网备用地址（可选）'),
          ),
          const SizedBox(height: 16),
          SelectableText(
            '已绑定证书指纹\n${widget.profile.fingerprint}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: widget.busy
                ? null
                : () async {
                    try {
                      await widget.onSave(
                        widget.profile.withAddresses(
                          _direct.text,
                          _fallback.text,
                        ),
                      );
                    } on Object catch (error) {
                      if (mounted) {
                        setState(
                          () => _error = error is ApiException
                              ? error.message
                              : '保存失败。',
                        );
                      }
                    }
                  },
            child: const Text('保存地址并重连'),
          ),
        ],
      ),
      const SizedBox(height: 20),
      const Text('直连失败会尝试已导入的备用地址。校园网设备隔离或不同网络之间，需要可达的公网地址或 TCP 隧道。'),
      const SizedBox(height: 16),
      if (widget.onOpenCache != null)
        Card(
          child: ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('手机缓存'),
            subtitle: const Text('查看缓存类型、大小和位置；仅清理本手机'),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.busy ? null : widget.onOpenCache,
          ),
        ),
      const SizedBox(height: 16),
      ListTile(
        leading: const Icon(Icons.description_outlined),
        title: const Text('开源许可证'),
        subtitle: const Text('EasyConnection · MIT 许可证与第三方声明'),
        onTap: () => showLicensePage(
          context: context,
          applicationName: 'EasyConnection',
          applicationVersion: '0.4.1',
        ),
      ),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: widget.busy
            ? null
            : () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('移除此电脑？'),
                    content: const Text('手机将删除连接凭据；电脑端授权可在托盘设置中撤销。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('移除'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) await widget.onForget();
              },
        child: const Text('移除此电脑'),
      ),
    ],
  );
}
