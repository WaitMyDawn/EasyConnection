import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:easy_connection/cache_page.dart';
import 'package:easy_connection/focused_input.dart';
import 'package:easy_connection/remote_desktop.dart';
import 'package:easy_connection/connection.dart';

Future<Uint8List> imageBytes(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Json frame(String id) => {
  'id': id,
  'displayId': 'monitor',
  'layoutId': 'layout',
  'width': 1000,
  'height': 500,
};

void main() {
  testWidgets(
    'stream updates retain the rendered frame while the next image decodes',
    (tester) async {
      final controller = RemoteDesktopController();
      final first = await tester.runAsync(() => imageBytes(Colors.red));
      final next = await tester.runAsync(() => imageBytes(Colors.blue));
      controller.replace(frame('one'), first!);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteViewport(
              controller: controller,
              onAction: (_) async {},
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      final render = tester.renderObject<RenderImage>(find.byType(RawImage));
      expect(render.image, isNotNull);
      final old = render.image;
      controller.replace(frame('two'), next!);
      await tester.pump();
      expect(render.image, isNotNull);
      expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);
      expect(old!.width, 8);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('right-click tool sends a right button and drag shows its path', (
    tester,
  ) async {
    final controller = RemoteDesktopController();
    final bytes = await tester.runAsync(() => imageBytes(Colors.green));
    controller.replace(frame('one'), bytes!);
    final actions = <Json>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteViewport(
            controller: controller,
            onAction: (a) async => actions.add(a),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '右键'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 260));
    await tester.pumpAndSettle();
    expect(actions.single['button'], 'right');
    await tester.tap(find.widgetWithText(ChoiceChip, '拖动'));
    await tester.pumpAndSettle();
    controller.live = true;
    final gesture = await tester.startGesture(const Offset(300, 240));
    await gesture.moveTo(const Offset(400, 280));
    await gesture.moveTo(const Offset(460, 290));
    controller.replace(frame('newer-live-frame'), bytes);
    await tester.pump();
    expect(
      find
          .byType(CustomPaint)
          .evaluate()
          .any((e) => (e.widget as CustomPaint).painter is DragMarker),
      isTrue,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(actions.last['type'], 'drag');
    expect(actions.last['snapshotId'], 'newer-live-frame');
    final count = actions.length;
    final cancelled = await tester.startGesture(const Offset(300, 240));
    await cancelled.moveTo(const Offset(400, 280));
    await cancelled.moveTo(const Offset(450, 290));
    controller.replace({
      ...frame('changed-layout'),
      'layoutId': 'new-layout',
    }, bytes);
    await tester.pump();
    await cancelled.up();
    await tester.pumpAndSettle();
    expect(actions.length, count);
    expect(controller.error, contains('显示器布局'));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'focus input preserves newlines without a window selector and rejects changed target',
    (tester) async {
      final target = <String, dynamic>{
        'id': 'first',
        'editable': true,
        'description': '已识别当前输入框',
      };
      final controller = RemoteDesktopController()..focus = target;
      final text = TextEditingController();
      final submitted = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusedInputSheet(
              controller: controller,
              target: target,
              text: text,
              onSubmit: (value, _) async => submitted.add(value),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '甲\n乙🙂');
      await tester.tap(find.widgetWithText(FilledButton, '输入到电脑'));
      expect(submitted, ['甲\n乙🙂']);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      controller.focus = {'id': 'different'};
      controller.changed();
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '输入到电脑'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      text.dispose();
    },
  );

  testWidgets(
    'phone cache lists type size location and only invokes the local cleaner',
    (tester) async {
      var clears = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneCachePage(
            inspect: () async => [
              {
                'name': '当前截图数据',
                'bytes': 2048,
                'entries': 1,
                'location': '手机进程内存',
                'clearable': true,
              },
              {
                'name': '应用临时文件',
                'bytes': 123,
                'entries': 1,
                'location': '/data/user/0/fixture/cache',
                'clearable': true,
              },
            ],
            clear: () async {
              clears++;
              return '本机已清理';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2.0 KiB'), findsOneWidget);
      expect(find.textContaining('/data/user/0/fixture/cache'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '清理手机缓存'));
      await tester.pumpAndSettle();
      expect(clears, 1);
      expect(find.text('本机已清理'), findsOneWidget);
    },
  );
}
