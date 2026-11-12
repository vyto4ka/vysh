import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/ui/theme/app_theme.dart';
import 'package:vysh/ui/widgets/context_menu.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  Future<GlobalKey<ContextMenuAreaState>> openMenu(WidgetTester tester) async {
    final key = GlobalKey<ContextMenuAreaState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(seed: Colors.purple, brightness: Brightness.dark),
        home: Scaffold(
          body: ContextMenuArea(key: key, child: const SizedBox.expand()),
        ),
      ),
    );
    key.currentState!.open(const Offset(100, 100), [
      menuItem('Action', onPressed: () {}),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Action'), findsOneWidget);
    return key;
  }

  testWidgets('context menu closes on a click outside its surface', (
    tester,
  ) async {
    final key = await openMenu(tester);
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isFalse);
    expect(find.text('Action'), findsNothing);
  });

  testWidgets('native window blur closes the menu and removes its listener', (
    tester,
  ) async {
    final listeners = windowManager.listeners.length;
    final key = await openMenu(tester);
    expect(windowManager.listeners.length, listeners + 1);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'window_manager',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', {'eventName': 'blur'}),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isFalse);
    expect(windowManager.listeners.length, listeners);
    expect(find.text('Action'), findsNothing);
    key.currentState!.open(const Offset(100, 100), [menuItem('Reopened')]);
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(windowManager.listeners.length, listeners);
  });

  testWidgets('only loss of focus in the owning view dismisses its menu', (
    tester,
  ) async {
    final key = await openMenu(tester);
    void blur(int viewId) => tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    blur(tester.view.viewId + 1);
    await tester.pump();
    expect(key.currentState!.isOpen, isTrue);
    blur(tester.view.viewId);
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isFalse);
  });

  testWidgets(
    'menu button loses its selected state when app becomes inactive',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MenuIconButton(
              tooltip: 'Layout',
              items: [menuItem('Action', onPressed: () {})],
            ),
          ),
        ),
      );
      final button = find.byType(IconButton);
      expect(tester.widget<IconButton>(button).isSelected, isFalse);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(button).isSelected, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text('Action'), findsNothing);
      expect(tester.widget<IconButton>(button).isSelected, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}
