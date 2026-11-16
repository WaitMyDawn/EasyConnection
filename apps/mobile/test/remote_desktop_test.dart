import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:easy_connection/remote_desktop.dart';

Uint8List fixtureImage() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jq3cAAAAASUVORK5CYII=',
);
RemoteDesktopController fixture() => RemoteDesktopController()
  ..pointerSupported = true
  ..replace({
    'id': 'test-image',
    'displayId': 'test-display',
    'layoutId': 'layout',
    'width': 1600,
    'height': 900,
    'cursor': {'x': 0.25, 'y': 0.75, 'inside': true, 'visible': true},
  }, fixtureImage());

void main() {
  test('clearing screenshots invalidates frame references and preserves capabilities', () {
    final controller = fixture();
    final epoch = controller.generation;
    controller.clear();
    expect(controller.image, isNull);
    expect(controller.snapshot, isNull);
    expect(controller.generation, greaterThan(epoch));
    expect(controller.pointerSupported, isTrue);
    controller.dispose();
  });
  test('cursor updates cannot cross display or layout identity', () {
    final controller = fixture();
    controller.cursor({
      'displayId': 'another',
      'layoutId': 'layout',
      'cursor': {'x': 0.9},
    });
    expect((controller.snapshot!['cursor'] as Map)['x'], 0.25);
    controller.cursor({
      'displayId': 'test-display',
      'layoutId': 'layout',
      'cursor': {'x': 0.5, 'y': 0.5, 'inside': true},
    });
    expect((controller.snapshot!['cursor'] as Map)['x'], 0.5);
    controller.dispose();
  });
  testWidgets(
    'directional micro controls move pixels and click at current pointer',
    (tester) async {
      final controller = fixture();
      final moves = <(int, int)>[];
      final clicks = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PointerControls(
              controller: controller,
              onMove: (dx, dy) async => moves.add((dx, dy)),
              onClick: (button) async => clicks.add(button),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.arrow_forward));
      expect(moves, [(5, 0)]);
      await tester.tap(find.text('左键'));
      await tester.tap(find.text('右键'));
      expect(clicks, ['left', 'right']);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      await tester.pump(const Duration(milliseconds: 460));
      await gesture.up();
      expect(moves.where((m) => m == (0, -5)).length, greaterThan(1));
      final count = moves.length;
      await tester.pump(const Duration(milliseconds: 500));
      expect(moves.length, count);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('landscape view requests orientation and fits a short screen', (
    tester,
  ) async {
    final controller = fixture();
    final methods = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        methods.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    tester.view.physicalSize = const Size(850, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: LandscapeDesktopPage(
          controller: controller,
          onAction: (_) async {},
          onMove: (_, _) async {},
          onClick: (_) async {},
          onRefresh: () async {},
          onMode: (_) async {},
          onInput: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('横屏桌面'), findsOneWidget);
    expect(
      find
          .byType(CustomPaint)
          .evaluate()
          .any((e) => (e.widget as CustomPaint).painter is CursorMarker),
      isTrue,
    );
    expect(
      methods
          .where((m) => m.method == 'SystemChrome.setPreferredOrientations')
          .first
          .arguments,
      ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(
      methods
          .where((m) => m.method == 'SystemChrome.setPreferredOrientations')
          .last
          .arguments,
      isEmpty,
    );
    controller.dispose();
  });
}
