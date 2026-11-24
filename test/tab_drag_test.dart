import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:vysh/ui/shell/tab_drag.dart';
import 'package:vysh/ui/shell/ui_state.dart';

void main() {
  group('shouldTearOffTab', () {
    test('Wayland relies exclusively on DropMonitor insideWindow state', () {
      expect(shouldTearOffTab(isWayland: true, insideWindow: false), isTrue);
      expect(shouldTearOffTab(isWayland: true, insideWindow: true), isFalse);
    });

    test('non-Wayland detaches when pointer left window or outside bounds', () {
      const bounds = Rect.fromLTWH(100, 100, 800, 600);
      expect(
        shouldTearOffTab(
          isWayland: false,
          insideWindow: false,
          cursorPoint: const Offset(200, 200),
          windowBounds: bounds,
        ),
        isTrue,
      );
      expect(
        shouldTearOffTab(
          isWayland: false,
          insideWindow: true,
          cursorPoint: const Offset(200, 200),
          windowBounds: bounds,
        ),
        isFalse,
      );
      expect(
        shouldTearOffTab(
          isWayland: false,
          insideWindow: true,
          cursorPoint: const Offset(50, 200),
          windowBounds: bounds,
        ),
        isTrue,
      );
      // Within 6px border tolerance does not accidentally tear off.
      expect(
        shouldTearOffTab(
          isWayland: false,
          insideWindow: true,
          cursorPoint: const Offset(95, 200),
          windowBounds: bounds,
        ),
        isFalse,
      );
    });
  });

  testWidgets(
    'WindowTabDragScope uses DropMonitor so onDropLeave clears inside state',
    (tester) async {
      final container = ProviderContainer(
        overrides: [nativeTabDragProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: WindowTabDragScope(child: SizedBox.expand()),
          ),
        ),
      );

      final monitorFinder = find.byType(DropMonitor);
      expect(monitorFinder, findsOneWidget);
      expect(find.byType(DropRegion), findsNothing);

      final monitor = tester.widget<DropMonitor>(monitorFinder);
      container.read(tabDragInsideWindowProvider.notifier).set(true);
      container.read(incomingTabDragProvider.notifier).set(true);

      monitor.onDropLeave?.call(DropEvent(session: _FakeDropSession()));
      expect(container.read(tabDragInsideWindowProvider), isFalse);
      expect(container.read(incomingTabDragProvider), isFalse);
    },
  );
}

class _FakeDropSession extends DropSession {
  @override
  Set<DropOperation> get allowedOperations => const {DropOperation.move};

  @override
  List<DropItem> get items => const [];

  @override
  Listenable get onDisposed => ValueNotifier<void>(null);
}
