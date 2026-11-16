import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'connection.dart';

class RemoteDesktopController extends ChangeNotifier {
  Uint8List? image;
  Json? snapshot;
  Json? focus;
  DesktopMode mode = DesktopMode.step;
  bool busy = false, live = false, pointerSupported = false;
  String? error;
  int generation = 0;
  bool _disposed = false;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void replace(Json metadata, Uint8List bytes) {
    if (_disposed) return;
    final old = image;
    snapshot = Map<String, dynamic>.from(metadata);
    image = bytes;
    if (old != null && !identical(old, bytes)) {
      unawaited(MemoryImage(old).evict());
    }
    changed();
  }

  void cursor(Json value) {
    if (snapshot == null ||
        value['displayId'] != snapshot!['displayId'] ||
        value['layoutId'] != snapshot!['layoutId']) {
      return;
    }
    snapshot = {...snapshot!, 'cursor': value['cursor']};
    changed();
  }

  void clear() {
    generation++;
    final old = image;
    image = null;
    snapshot = null;
    if (old != null) unawaited(MemoryImage(old).evict());
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    generation++;
    final old = image;
    image = null;
    snapshot = null;
    if (old != null) unawaited(MemoryImage(old).evict());
    super.dispose();
  }
}

enum PointerTool { tap, rightClick, drag }

enum DesktopMode { realtime, step }

class RemoteViewport extends StatefulWidget {
  final RemoteDesktopController controller;
  final Future<void> Function(Json) onAction;
  const RemoteViewport({
    super.key,
    required this.controller,
    required this.onAction,
  });
  @override
  State<RemoteViewport> createState() => _RemoteViewportState();
}

class _RemoteViewportState extends State<RemoteViewport> {
  PointerTool _tool = PointerTool.tap;
  Offset? _start, _end;
  String? _reference;
  String? _referenceDisplay, _referenceLayout;
  final _transformation = TransformationController();
  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  void _click(Offset point, Size size, String button) {
    final frame = widget.controller.snapshot;
    if (frame == null) return;
    widget.onAction({
      'type': 'click',
      'snapshotId': frame['id'],
      'x': (point.dx / size.width).clamp(0, 1),
      'y': (point.dy / size.height).clamp(0, 1),
      'button': button,
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      final frame = state.snapshot;
      return Column(
        children: [
          Expanded(
            child: state.image == null || frame == null
                ? const Center(child: Text('点击刷新获取桌面'))
                : LayoutBuilder(
                    builder: (context, bounds) {
                      final ratio =
                          (frame['width'] as num) / (frame['height'] as num);
                      final width = math.min(
                        bounds.maxWidth,
                        bounds.maxHeight * ratio,
                      );
                      final height = width / ratio;
                      final cursor = frame['cursor'] as Json?;
                      final dragging = _tool == PointerTool.drag;
                      return Center(
                        child: SizedBox(
                          width: width,
                          height: height,
                          child: InteractiveViewer(
                            transformationController: _transformation,
                            maxScale: 5,
                            panEnabled: !dragging,
                            scaleEnabled: !dragging,
                            child: GestureDetector(
                              onTapUp: state.busy || dragging
                                  ? null
                                  : (d) => _click(
                                      d.localPosition,
                                      Size(width, height),
                                      _tool == PointerTool.rightClick
                                          ? 'right'
                                          : 'left',
                                    ),
                              onDoubleTapDown:
                                  state.busy ||
                                      dragging ||
                                      _tool == PointerTool.rightClick
                                  ? null
                                  : (d) => _end = d.localPosition,
                              onDoubleTap:
                                  state.busy ||
                                      dragging ||
                                      _tool == PointerTool.rightClick
                                  ? null
                                  : () {
                                      if (_end != null) {
                                        _click(
                                          _end!,
                                          Size(width, height),
                                          _tool == PointerTool.rightClick
                                              ? 'right'
                                              : 'double',
                                        );
                                      }
                                    },
                              onLongPressStart: state.busy || dragging
                                  ? null
                                  : (d) => _click(
                                      d.localPosition,
                                      Size(width, height),
                                      'right',
                                    ),
                              onPanStart: !dragging || state.busy
                                  ? null
                                  : (d) => setState(() {
                                      _start = d.localPosition;
                                      _end = _start;
                                      _reference = frame['id'] as String;
                                      _referenceDisplay =
                                          frame['displayId'] as String;
                                      _referenceLayout =
                                          frame['layoutId'] as String;
                                    }),
                              onPanUpdate: !dragging || state.busy
                                  ? null
                                  : (d) =>
                                        setState(() => _end = d.localPosition),
                              onPanCancel: () => setState(() {
                                _start = null;
                                _end = null;
                              }),
                              onPanEnd: !dragging || state.busy
                                  ? null
                                  : (_) {
                                      if (_start == null || _end == null) {
                                        return;
                                      }
                                      final current = state.snapshot;
                                      if (current?['displayId'] !=
                                              _referenceDisplay ||
                                          current?['layoutId'] !=
                                              _referenceLayout) {
                                        setState(() {
                                          _start = null;
                                          _end = null;
                                        });
                                        state.error = '显示器布局已变化，请重新拖动。';
                                        state.changed();
                                        return;
                                      }
                                      widget.onAction({
                                        'type': 'drag',
                                        'snapshotId': state.live
                                            ? current!['id']
                                            : _reference,
                                        'fromX': (_start!.dx / width).clamp(
                                          0,
                                          1,
                                        ),
                                        'fromY': (_start!.dy / height).clamp(
                                          0,
                                          1,
                                        ),
                                        'x': (_end!.dx / width).clamp(0, 1),
                                        'y': (_end!.dy / height).clamp(0, 1),
                                      });
                                      setState(() {
                                        _start = null;
                                        _end = null;
                                      });
                                    },
                              child: ClipRect(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.memory(
                                      state.image!,
                                      fit: BoxFit.fill,
                                      gaplessPlayback: true,
                                      excludeFromSemantics: true,
                                    ),
                                    if (cursor?['inside'] == true)
                                      Positioned(
                                        left:
                                            (cursor!['x'] as num)
                                                    .toDouble()
                                                    .clamp(0, 1) *
                                                (width - 1) -
                                            10,
                                        top:
                                            (cursor['y'] as num)
                                                    .toDouble()
                                                    .clamp(0, 1) *
                                                (height - 1) -
                                            10,
                                        child: const IgnorePointer(
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CustomPaint(
                                              painter: CursorMarker(),
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (_start != null && _end != null)
                                      IgnorePointer(
                                        child: CustomPaint(
                                          painter: DragMarker(_start!, _end!),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in {
                PointerTool.tap: '点按',
                PointerTool.rightClick: '右键',
                PointerTool.drag: '拖动',
              }.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _tool == entry.key,
                  onSelected: state.busy
                      ? null
                      : (_) => setState(() {
                          _tool = entry.key;
                          _start = null;
                          _end = null;
                        }),
                ),
              AnimatedBuilder(
                animation: _transformation,
                builder: (context, _) => TextButton(
                  onPressed: _transformation.value == Matrix4.identity()
                      ? null
                      : () => _transformation.value = Matrix4.identity(),
                  child: const Text('复位缩放'),
                ),
              ),
            ],
          ),
          if (_tool == PointerTool.drag)
            const Text(
              '在画面上划动，松手执行拖动；切回点按后可双指缩放',
              style: TextStyle(fontSize: 11),
            ),
          if (_tool == PointerTool.rightClick)
            const Text('点按画面即可在该位置右击', style: TextStyle(fontSize: 11)),
        ],
      );
    },
  );
}

class DragMarker extends CustomPainter {
  final Offset from, to;
  DragMarker(this.from, this.to);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff72f3ff)
      ..strokeWidth = 3;
    canvas.drawLine(from, to, paint);
    canvas.drawCircle(from, 5, paint);
    canvas.drawCircle(to, 5, paint);
  }

  @override
  bool shouldRepaint(covariant DragMarker old) =>
      old.from != from || old.to != to;
}

class CursorMarker extends CustomPainter {
  const CursorMarker();
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.black;
    canvas.drawCircle(center, 5, paint);
    paint
      ..strokeWidth = 1.5
      ..color = const Color(0xff72f3ff);
    canvas.drawCircle(center, 5, paint);
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      paint,
    );
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);
  }

  @override
  bool shouldRepaint(covariant CursorMarker oldDelegate) => false;
}

class PointerControls extends StatefulWidget {
  final RemoteDesktopController controller;
  final Future<void> Function(int dx, int dy) onMove;
  final Future<void> Function(String button) onClick;
  const PointerControls({
    super.key,
    required this.controller,
    required this.onMove,
    required this.onClick,
  });
  @override
  State<PointerControls> createState() => _PointerControlsState();
}

class _PointerControlsState extends State<PointerControls> {
  int _step = 5;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final state = widget.controller;
      final inside = (state.snapshot?['cursor'] as Json?)?['inside'] == true;
      final enabled =
          state.pointerSupported &&
          state.image != null &&
          inside &&
          state.error == null;
      Widget arrow(String label, IconData icon, int dx, int dy) =>
          HoldArrowButton(
            label: label,
            icon: icon,
            enabled: enabled,
            blocked: state.busy,
            onPressed: () {
              if (!state.busy) widget.onMove(dx * _step, dy * _step);
            },
          );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('鼠标微调'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _step,
                items: [
                  for (final step in [1, 5, 20])
                    DropdownMenuItem(value: step, child: Text('$step 像素')),
                ],
                onChanged: (value) => setState(() => _step = value!),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 52),
              arrow('鼠标向上', Icons.arrow_upward, 0, -1),
              const SizedBox(width: 52),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              arrow('鼠标向左', Icons.arrow_back, -1, 0),
              const SizedBox(
                width: 52,
                height: 48,
                child: Icon(Icons.mouse_outlined, color: Colors.white54),
              ),
              arrow('鼠标向右', Icons.arrow_forward, 1, 0),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 52),
              arrow('鼠标向下', Icons.arrow_downward, 0, 1),
              const SizedBox(width: 52),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: enabled && !state.busy
                    ? () => widget.onClick('left')
                    : null,
                child: const Text('左键'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: enabled && !state.busy
                    ? () => widget.onClick('right')
                    : null,
                child: const Text('右键'),
              ),
            ],
          ),
          if (!enabled)
            Text(
              state.pointerSupported ? '先刷新，或点按画面把鼠标移入当前显示器' : '需更新电脑端以使用鼠标微调',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      );
    },
  );
}

class HoldArrowButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool enabled, blocked;
  final VoidCallback onPressed;
  const HoldArrowButton({
    super.key,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.blocked,
    required this.onPressed,
  });
  @override
  State<HoldArrowButton> createState() => _HoldArrowButtonState();
}

class _HoldArrowButtonState extends State<HoldArrowButton> {
  Timer? _timer;
  bool _pressed = false;
  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (mounted && _pressed) setState(() => _pressed = false);
  }

  void _activate() {
    if (widget.enabled && !widget.blocked) widget.onPressed();
  }

  @override
  void didUpdateWidget(covariant HoldArrowButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _stop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '${widget.label}（按住连续移动）',
    child: Semantics(
      label: widget.label,
      button: true,
      enabled: widget.enabled && !widget.blocked,
      onTap: _activate,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: Listener(
          onPointerDown: !widget.enabled
              ? null
              : (_) {
                  _stop();
                  setState(() => _pressed = true);
                  _activate();
                  _timer = Timer.periodic(
                    const Duration(milliseconds: 150),
                    (_) => _activate(),
                  );
                },
          onPointerUp: (_) => _stop(),
          onPointerCancel: (_) => _stop(),
          child: Container(
            width: 52,
            height: 44,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: _pressed
                  ? const Color(0xff405888)
                  : const Color(0xff222c3e),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              widget.icon,
              color: widget.enabled && !widget.blocked
                  ? Colors.white
                  : Colors.white30,
            ),
          ),
        ),
      ),
    ),
  );
}

class LandscapeDesktopPage extends StatefulWidget {
  final RemoteDesktopController controller;
  final Future<void> Function(Json) onAction;
  final Future<void> Function(int, int) onMove;
  final Future<void> Function(String) onClick;
  final Future<void> Function() onRefresh, onInput;
  final Future<void> Function(DesktopMode) onMode;
  const LandscapeDesktopPage({
    super.key,
    required this.controller,
    required this.onAction,
    required this.onMove,
    required this.onClick,
    required this.onRefresh,
    required this.onMode,
    required this.onInput,
  });
  @override
  State<LandscapeDesktopPage> createState() => _LandscapeDesktopPageState();
}

class _LandscapeDesktopPageState extends State<LandscapeDesktopPage> {
  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations([]));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  BackButton(onPressed: () => Navigator.pop(context)),
                  const Expanded(child: Text('横屏桌面')),
                  IconButton(
                    tooltip: '输入到当前焦点',
                    onPressed: widget.controller.busy ? null : widget.onInput,
                    icon: const Icon(Icons.keyboard),
                  ),
                  IconButton(
                    tooltip: '刷新截图',
                    onPressed: widget.controller.busy ? null : widget.onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
                  PopupMenuButton<DesktopMode>(
                    tooltip: '查看模式',
                    enabled: !widget.controller.busy,
                    onSelected: widget.onMode,
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: DesktopMode.realtime,
                        child: Text('实时控制'),
                      ),
                      const PopupMenuItem(
                        value: DesktopMode.step,
                        child: Text('单步查看'),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        widget.controller.mode == DesktopMode.realtime
                            ? '实时控制 ▾'
                            : '单步查看 ▾',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              widget.controller.mode == DesktopMode.realtime
                  ? (widget.controller.live
                        ? '实时控制 · 画面自动同步'
                        : '实时控制已断开，请重新选择模式')
                  : '单步查看 · 每次操作后更新截图',
            ),
            if (widget.controller.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  widget.controller.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final canvas = RemoteViewport(
                    controller: widget.controller,
                    onAction: widget.onAction,
                  );
                  final controls = SingleChildScrollView(
                    child: PointerControls(
                      controller: widget.controller,
                      onMove: widget.onMove,
                      onClick: widget.onClick,
                    ),
                  );
                  return bounds.maxWidth > bounds.maxHeight
                      ? Row(
                          children: [
                            Expanded(child: canvas),
                            SizedBox(width: 190, child: controls),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(child: canvas),
                            SizedBox(
                              height: math.min(230, bounds.maxHeight / 2),
                              child: controls,
                            ),
                          ],
                        );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
