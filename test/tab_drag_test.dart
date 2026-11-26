import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:vysh/infra/platform/desktop_env.dart';
import 'package:vysh/ui/shell/tab_drag.dart';
import 'package:vysh/ui/shell/ui_state.dart';

void main() {
  group('DesktopEnv.isWaylandFor', () {
    test(
      'detects Wayland and Hyprland/Sway/Niri, respects GDK_BACKEND=x11',
      () {
        expect(
          DesktopEnv.isWaylandFor({
            'WAYLAND_DISPLAY': 'wayland-1',
          }, isLinux: true),
          isTrue,
        );
        expect(
          DesktopEnv.isWaylandFor({
            'HYPRLAND_INSTANCE_SIGNATURE': 'abc123',
          }, isLinux: true),
          isTrue,
        );
        expect(
          DesktopEnv.isWaylandFor({
            'XDG_SESSION_TYPE': 'wayland',
          }, isLinux: true),
          isTrue,
        );
        expect(
          DesktopEnv.isWaylandFor({
            'WAYLAND_DISPLAY': 'wayland-1',
            'HYPRLAND_INSTANCE_SIGNATURE': 'abc123',
            'GDK_BACKEND': 'x11',
          }, isLinux: true),
          isFalse,
        );
        expect(
          DesktopEnv.isWaylandFor({
            'WAYLAND_DISPLAY': 'wayland-1',
          }, isLinux: false),
          isFalse,
        );
      },
    );
  });

  group('shouldTearOffTab & resolveWaylandInsideWindow', () {
    test('Wayland relies exclusively on insideWindow state', () {
      expect(shouldTearOffTab(isWayland: true, insideWindow: false), isTrue);
      expect(shouldTearOffTab(isWayland: true, insideWindow: true), isFalse);
    });

    test(
      'Hyprland fast flick or upward exit tears off even when DropMonitor missed onDropLeave',
      () async {
        // DropMonitor stayed true (e.g. <=1 drag_motion or schedule_next race),
        // compositor cleared wl_pointer on start_drag and did not resend enter.
        final inside = await resolveWaylandInsideWindow(
          initialDropInside: true,
          pointerExitedDuringDrag: true,
          readDropInside: () => true,
          readPointerInside: () => false,
          settleDelay: Duration.zero,
        );
        expect(inside, isFalse);
        expect(shouldTearOffTab(isWayland: true, insideWindow: inside), isTrue);
      },
    );

    test(
      'Hyprland unaccepted drop inside own window does not tear off when wl_pointer.enter returns',
      () async {
        var pointerInside = false;
        Future<void>.microtask(() => pointerInside = true);
        final inside = await resolveWaylandInsideWindow(
          initialDropInside: true,
          pointerExitedDuringDrag: true,
          // abortDrag() sends wl_data_device.leave even inside own surface,
          // so DropMonitor may become false while wl_pointer.enter becomes true.
          readDropInside: () => false,
          readPointerInside: () => pointerInside,
          settleDelay: const Duration(milliseconds: 5),
        );
        expect(inside, isTrue);
        expect(
          shouldTearOffTab(isWayland: true, insideWindow: inside),
          isFalse,
        );
      },
    );

    test(
      'fallback compositor without wl_pointer exit honors deferred DropMonitor leave',
      () async {
        var dropInside = true;
        Future<void>.microtask(() => dropInside = false);
        final inside = await resolveWaylandInsideWindow(
          initialDropInside: true,
          pointerExitedDuringDrag: false,
          readDropInside: () => dropInside,
          readPointerInside: () => true,
          settleDelay: const Duration(milliseconds: 5),
        );
        expect(inside, isFalse);
      },
    );

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
    'WindowTabDragScope tracks DropMonitor leave and pre-DnD upward pointer exit',
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

      // Simulate grabbing a tab near y = 10 and dragging upward to y = -6
      // during implicit grab before wl_data_device.start_drag begins.
      final gesture = await tester.startGesture(
        const Offset(120, 10),
        kind: PointerDeviceKind.mouse,
      );
      expect(container.read(pointerInsideWindowProvider), isTrue);
      await gesture.moveTo(const Offset(120, -6));
      expect(container.read(pointerInsideWindowProvider), isFalse);
      await gesture.up();

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
