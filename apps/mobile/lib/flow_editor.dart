import 'package:material_ui/material_ui.dart';

import 'connection.dart';

const actionLabels = <String, String>{
  'launch': '启动已注册应用',
  'focusWindow': '激活目标窗口',
  'click': '点击窗口位置',
  'scroll': '滚动窗口',
  'drag': '拖拽窗口内位置',
  'typeText': '输入文字',
  'keyChord': '按快捷键',
  'wait': '等待指定时间',
  'waitForElement': '等待控件出现',
  'invoke': '调用按钮',
  'setValue': '设置控件文字',
  'assertElement': '检查控件或文字',
  'screenshot': '获取截图',
};

class FlowEditor extends StatefulWidget {
  final Json? flow;
  final List<Json> windows, apps;
  final Future<Json> Function(String)? inspect;
  const FlowEditor({
    super.key,
    this.flow,
    required this.windows,
    required this.apps,
    this.inspect,
  });
  @override
  State<FlowEditor> createState() => _FlowEditorState();
}

class _FlowEditorState extends State<FlowEditor> {
  late final _name = TextEditingController(
    text: widget.flow?['name'] as String? ?? '新建流程',
  );
  late final _description = TextEditingController(
    text: widget.flow?['description'] as String? ?? '',
  );
  late final List<Json> _steps = (widget.flow?['steps'] as List? ?? [])
      .map((s) => Map<String, dynamic>.from(s as Json))
      .toList();
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _step([int? index]) async {
    final result = await Navigator.of(context).push<Json>(
      MaterialPageRoute(
        builder: (_) => StepEditor(
          step: index == null ? null : _steps[index],
          windows: widget.windows,
          apps: widget.apps,
          inspect: widget.inspect,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        if (index == null) {
          _steps.add(result);
        } else {
          _steps[index] = result;
        }
      });
    }
  }

  void _save() {
    if (_name.text.trim().isEmpty || _steps.isEmpty) {
      setState(() => _error = '请填写流程名称并添加至少一个动作。');
      return;
    }
    final parameters = <String>{};
    for (final step in _steps) {
      for (final match in RegExp(
        r'\$\{([a-zA-Z][a-zA-Z0-9_]*)\}',
      ).allMatches(step['text'] as String? ?? '')) {
        parameters.add(match[1]!);
      }
    }
    Navigator.pop(context, <String, dynamic>{
      'id': widget.flow?['id'] ?? 'flow_${requestId().substring(0, 12)}',
      'name': _name.text.trim(),
      'description': _description.text.trim(),
      'version': 1,
      'parameters': [
        for (final name in parameters)
          {'name': name, 'label': name, 'required': true},
      ],
      'steps': _steps,
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('编辑预置流程'),
      actions: [
        if (widget.flow != null)
          IconButton(
            tooltip: '删除流程',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除此流程？'),
                  content: const Text('已提交的任务不会受影响。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                Navigator.pop(context, <String, dynamic>{
                  '_delete': true,
                  'id': widget.flow!['id'],
                });
              }
            },
          ),
        TextButton(onPressed: _save, child: const Text('保存')),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '流程名称'),
            maxLength: 100,
          ),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: '说明'),
          ),
          const SizedBox(height: 12),
          const Text(r'文字中使用 ${message} 等参数，运行时即可填写。点击位置相对于目标窗口。'),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
          const SizedBox(height: 8),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: _steps.length,
              onReorderItem: (oldIndex, newIndex) => setState(() {
                _steps.insert(newIndex, _steps.removeAt(oldIndex));
              }),
              itemBuilder: (context, index) => Card(
                key: ObjectKey(_steps[index]),
                child: ListTile(
                  leading: Text('${index + 1}'),
                  title: Text(
                    actionLabels[_steps[index]['type']] ??
                        _steps[index]['type'] as String,
                  ),
                  subtitle: Text(
                    (_steps[index]['text'] ??
                            (_steps[index]['selector']
                                as Json?)?['windowTitle'] ??
                            '')
                        .toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _step(index),
                  trailing: IconButton(
                    tooltip: '删除步骤',
                    onPressed: () => setState(() => _steps.removeAt(index)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _steps.length >= 100 ? null : _step,
              icon: const Icon(Icons.add),
              label: const Text('添加动作'),
            ),
          ),
        ],
      ),
    ),
  );
}

class StepEditor extends StatefulWidget {
  final Json? step;
  final List<Json> windows, apps;
  final Future<Json> Function(String)? inspect;
  const StepEditor({
    super.key,
    this.step,
    required this.windows,
    required this.apps,
    this.inspect,
  });
  @override
  State<StepEditor> createState() => _StepEditorState();
}

class _StepEditorState extends State<StepEditor> {
  late String _type = widget.step?['type'] as String? ?? 'focusWindow';
  late String? _appId = widget.step?['appId'] as String?;
  late final _title = TextEditingController(
    text: (widget.step?['selector'] as Json?)?['windowTitle'] as String? ?? '',
  );
  late final _process = TextEditingController(
    text: (widget.step?['selector'] as Json?)?['processName'] as String? ?? '',
  );
  late final _element = TextEditingController(
    text: (widget.step?['selector'] as Json?)?['name'] as String? ?? '',
  );
  late final _automationId = TextEditingController(
    text: (widget.step?['selector'] as Json?)?['automationId'] as String? ?? '',
  );
  late final _text = TextEditingController(
    text: widget.step?['text'] as String? ?? '',
  );
  late final _keys = TextEditingController(
    text: (widget.step?['keys'] as List? ?? []).join('+'),
  );
  late final _x = TextEditingController(text: '${widget.step?['x'] ?? 0.5}');
  late final _y = TextEditingController(text: '${widget.step?['y'] ?? 0.5}');
  late final _fromX = TextEditingController(
    text: '${widget.step?['fromX'] ?? 0.2}',
  );
  late final _fromY = TextEditingController(
    text: '${widget.step?['fromY'] ?? 0.2}',
  );
  late final _wheel = TextEditingController(
    text: '${widget.step?['wheelDelta'] ?? -360}',
  );
  late final _delay = TextEditingController(
    text: '${widget.step?['delayMs'] ?? 1000}',
  );
  late final _timeout = TextEditingController(
    text: '${widget.step?['timeoutMs'] ?? 5000}',
  );
  late String _button = widget.step?['button'] as String? ?? 'left';
  String? _selectedWindowId;
  bool _reading = false;
  String? _error;
  bool get _needsWindow => !['launch', 'wait', 'screenshot'].contains(_type);
  bool get _needsElement =>
      ['invoke', 'setValue', 'waitForElement', 'assertElement'].contains(_type);
  Future<void> _inspect() async {
    setState(() {
      _reading = true;
      _error = null;
    });
    try {
      final catalog = await widget.inspect!(_selectedWindowId!);
      if (!mounted) return;
      final elements = (catalog['elements'] as List).cast<Json>();
      final selected = await showModalBottomSheet<Json>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    catalog['truncated'] == true
                        ? '已截取前 500 个控件，列表可能不完整。'
                        : '来自应用暴露的 UI Automation；未列出不代表不存在。',
                  ),
                ),
                Expanded(
                  child: elements.isEmpty
                      ? const Center(child: Text('未读到可定位控件，可手动配置或使用截图操作。'))
                      : ListView.builder(
                          itemCount: elements.length,
                          itemBuilder: (context, index) {
                            final element = elements[index];
                            return ListTile(
                              title: Text(
                                (element['name'] as String).isEmpty
                                    ? element['controlType'] as String
                                    : element['name'] as String,
                              ),
                              subtitle: Text(
                                '${element['controlType']} · ${element['automationId']}',
                              ),
                              enabled: element['enabled'] == true,
                              onTap: () => Navigator.pop(context, element),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
      if (selected != null && mounted) {
        setState(() {
          _element.text = selected['name'] as String;
          _automationId.text = selected['automationId'] as String;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ApiException
              ? error.message
              : '无法读取控件，请检查目标应用。',
        );
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _process,
      _element,
      _automationId,
      _text,
      _keys,
      _x,
      _y,
      _fromX,
      _fromY,
      _wheel,
      _delay,
      _timeout,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final selector = <String, dynamic>{
      if (_title.text.isNotEmpty) 'windowTitle': _title.text,
      if (_process.text.isNotEmpty) 'processName': _process.text,
      if (_needsElement && _element.text.isNotEmpty) 'name': _element.text,
      if (_needsElement && _automationId.text.isNotEmpty)
        'automationId': _automationId.text,
    };
    final x = double.tryParse(_x.text),
        y = double.tryParse(_y.text),
        delay = int.tryParse(_delay.text),
        timeout = int.tryParse(_timeout.text);
    String? error;
    if (_needsWindow && _title.text.isEmpty && _process.text.isEmpty) {
      error = '请选择窗口或填写进程名。';
    } else if (_needsElement &&
        _element.text.isEmpty &&
        _automationId.text.isEmpty) {
      error = '请填写控件名称或 AutomationId。';
    } else if (_type == 'launch' && _appId == null) {
      error = '请先在电脑端注册应用，然后选择。';
    } else if (['click', 'scroll', 'drag'].contains(_type) &&
        (x == null ||
            y == null ||
            !x.isFinite ||
            !y.isFinite ||
            x < 0 ||
            x > 1 ||
            y < 0 ||
            y > 1)) {
      error = '坐标必须在 0–1 之间。';
    } else if (_type == 'drag' &&
        (double.tryParse(_fromX.text) == null ||
            double.tryParse(_fromY.text) == null ||
            !(double.parse(_fromX.text) >= 0 &&
                double.parse(_fromX.text) <= 1 &&
                double.parse(_fromY.text) >= 0 &&
                double.parse(_fromY.text) <= 1))) {
      error = '拖拽起点必须在 0–1 之间。';
    } else if (_type == 'scroll' &&
        (int.tryParse(_wheel.text) == null ||
            int.parse(_wheel.text) == 0 ||
            int.parse(_wheel.text).abs() > 1200)) {
      error = '滚动量必须在 -1200–1200 之间且不能为零。';
    } else if (_type == 'wait' &&
        (delay == null || delay < 0 || delay > 30000)) {
      error = '等待时间必须在 0–30000 毫秒之间。';
    } else if (timeout == null || timeout < 100 || timeout > 30000) {
      error = '超时必须在 100–30000 毫秒之间。';
    } else if (_type == 'keyChord' && _keys.text.trim().isEmpty) {
      error = '请输入快捷键，如 CTRL+ENTER。';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'type': _type,
      'timeoutMs': timeout,
      if (_needsWindow) 'selector': selector,
      if (_type == 'launch') 'appId': _appId,
      if (['typeText', 'setValue'].contains(_type) ||
          (_type == 'assertElement' && _text.text.isNotEmpty))
        'text': _text.text,
      if (_type == 'keyChord')
        'keys': _keys.text
            .toUpperCase()
            .split('+')
            .map((k) => k.trim())
            .toList(),
      if (['click', 'scroll', 'drag'].contains(_type)) ...{
        'x': x,
        'y': y,
        'button': _button,
      },
      if (_type == 'drag') ...{
        'fromX': double.parse(_fromX.text),
        'fromY': double.parse(_fromY.text),
      },
      if (_type == 'scroll') 'wheelDelta': int.parse(_wheel.text),
      if (_type == 'wait') 'delayMs': delay,
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('配置动作'),
      actions: [TextButton(onPressed: _save, child: const Text('完成'))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        DropdownButtonFormField<String>(
          initialValue: _type,
          decoration: const InputDecoration(labelText: '动作类型'),
          items: [
            for (final entry in actionLabels.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) => setState(() => _type = value!),
        ),
        const SizedBox(height: 20),
        if (_type == 'launch') ...[
          DropdownButtonFormField<String>(
            initialValue: widget.apps.any((a) => a['id'] == _appId)
                ? _appId
                : null,
            decoration: const InputDecoration(labelText: '电脑端注册的应用'),
            items: [
              for (final app in widget.apps)
                DropdownMenuItem(
                  value: app['id'] as String,
                  child: Text(app['name'] as String),
                ),
            ],
            onChanged: (value) => _appId = value,
          ),
          const SizedBox(height: 12),
          const Text('可执行文件与启动参数由电脑端管理。'),
        ],
        if (_needsWindow) ...[
          DropdownButtonFormField<String>(
            isExpanded: true,
            decoration: const InputDecoration(labelText: '从当前窗口填入'),
            items: [
              for (final window in widget.windows)
                DropdownMenuItem(
                  value: window['id'] as String,
                  child: Text(
                    window['title'] as String,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) {
              final window = widget.windows.firstWhere((w) => w['id'] == id);
              setState(() {
                _selectedWindowId = id;
                _title.text = window['title'] as String;
                _process.text = window['processName'] as String;
              });
            },
          ),
          const SizedBox(height: 16),
          _field(_process, '进程名（不含 .exe）'),
          _field(_title, '窗口标题（精确匹配，可留空）'),
          const Text('匹配多个窗口时会停止执行，请补充唯一定位条件。'),
          const SizedBox(height: 16),
        ],
        if (_needsElement) ...[
          OutlinedButton.icon(
            onPressed:
                _selectedWindowId == null || widget.inspect == null || _reading
                ? null
                : _inspect,
            icon: const Icon(Icons.account_tree_outlined),
            label: Text(_reading ? '正在读取…' : '读取选中窗口的控件'),
          ),
          const SizedBox(height: 12),
          _field(_element, '控件名称'),
          _field(_automationId, 'AutomationId（可选）'),
        ],
        if (['typeText', 'setValue', 'assertElement'].contains(_type))
          _field(
            _text,
            _type == 'assertElement' ? '预期文字（留空仅检查存在）' : r'文字，支持 ${message} 参数',
            lines: 5,
          ),
        if (_type == 'keyChord') _field(_keys, '按键，如 CTRL+ENTER'),
        if (['click', 'scroll', 'drag'].contains(_type)) ...[
          _field(_x, '窗口内横向位置（0–1）'),
          _field(_y, '窗口内纵向位置（0–1）'),
          DropdownButtonFormField<String>(
            initialValue: _button,
            decoration: const InputDecoration(labelText: '鼠标按钮'),
            items: const [
              DropdownMenuItem(value: 'left', child: Text('左键')),
              DropdownMenuItem(value: 'right', child: Text('右键')),
              DropdownMenuItem(value: 'double', child: Text('双击')),
            ],
            onChanged: (value) => _button = value!,
          ),
        ],
        if (_type == 'drag') ...[
          _field(_fromX, '拖拽起点横向位置（0–1）'),
          _field(_fromY, '拖拽起点纵向位置（0–1）'),
        ],
        if (_type == 'scroll') _field(_wheel, '滚动量，120 为一格'),
        if (_type == 'wait') _field(_delay, '等待毫秒数（最多 30000）'),
        if (_type == 'waitForElement') _field(_timeout, '等待超时毫秒数'),
        const SizedBox(height: 16),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
        FilledButton(onPressed: _save, child: const Text('保存动作')),
      ],
    ),
  );
  Widget _field(
    TextEditingController controller,
    String label, {
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      maxLines: lines,
      decoration: InputDecoration(labelText: label),
    ),
  );
}
