import 'package:material_ui/material_ui.dart';

import 'connection.dart';
import 'remote_desktop.dart';

class FocusedInputSheet extends StatelessWidget {
  final RemoteDesktopController controller;
  final Json target;
  final TextEditingController text;
  final Future<void> Function(String text, String focusId) onSubmit;
  final Future<void> Function(List<String> keys, String focusId)? onKey;
  const FocusedInputSheet({
    super.key,
    required this.controller,
    required this.target,
    required this.text,
    required this.onSubmit,
    this.onKey,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final changed = controller.focus?['id'] != target['id'];
      return Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('输入到电脑当前焦点', style: Theme.of(context).textTheme.titleLarge),
              Text(
                changed
                    ? '电脑焦点已变化，请关闭后重新点击输入位置。'
                    : target['description'] as String,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                autofocus: true,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '文字内容',
                  hintText: '保留换行，不自动发送 Enter',
                ),
              ),
              const SizedBox(height: 12),
              if (controller.error != null)
                Text(
                  controller.error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              FilledButton(
                onPressed:
                    controller.busy || changed || target['editable'] == false
                    ? null
                    : () => onSubmit(text.text, target['id'] as String),
                child: Text(controller.busy ? '正在输入…' : '输入到电脑'),
              ),
              if (onKey != null)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final key in ['ENTER', 'TAB', 'ESC'])
                      OutlinedButton(
                        onPressed: controller.busy || changed
                            ? null
                            : () => onKey!([key], target['id'] as String),
                        child: Text(key == 'ENTER' ? 'Enter（发送/确认）' : key),
                      ),
                  ],
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('收起键盘'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
