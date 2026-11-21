import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/infra/platform/memory_trimmer.dart';
import 'package:vysh/ui/motion/layered_switcher.dart';
import 'package:vysh/ui/motion/smooth_scroll.dart';
import 'package:vysh/ui/widgets/memory_lifecycle_host.dart';
import 'package:xterm2/xterm.dart';

void main() {
  testWidgets(
    'LayeredSwitcher(lazy: true) не монтирует скрытую вкладку до первого визита',
    (tester) async {
      var secondBuilt = 0;
      final index = ValueNotifier(0);
      addTearDown(index.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: index,
            builder: (context, current, _) => LayeredSwitcher(
              index: current,
              lazy: true,
              children: [
                const Text('first'),
                Builder(
                  builder: (_) {
                    secondBuilt++;
                    return const Text('second');
                  },
                ),
              ],
            ),
          ),
        ),
      );

      expect(secondBuilt, 0);
      expect(find.text('second', skipOffstage: false), findsNothing);

      index.value = 1;
      await tester.pumpAndSettle();
      expect(secondBuilt, greaterThan(0));
      expect(find.text('second'), findsOneWidget);

      // После первого открытия скрытая вкладка остаётся в дереве (Offstage).
      index.value = 0;
      await tester.pumpAndSettle();
      expect(find.text('second', skipOffstage: false), findsOneWidget);
    },
  );

  testWidgets('ScrollEdgeFade не использует ShaderMask (saveLayer)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 120,
            child: ScrollEdgeFade(
              child: ListView.builder(
                itemCount: 30,
                itemExtent: 40,
                itemBuilder: (_, i) => Text('row $i'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('MemoryTrimmer применяет экономные лимиты ImageCache', (
    tester,
  ) async {
    final images = PaintingBinding.instance.imageCache;
    final prevBytes = images.maximumSizeBytes;
    final prevCount = images.maximumSize;
    addTearDown(() {
      images.maximumSizeBytes = prevBytes;
      images.maximumSize = prevCount;
    });

    MemoryTrimmer.configureStartupLimits();
    expect(images.maximumSizeBytes, MemoryTrimmer.maxImageCacheBytes);
    expect(images.maximumSize, MemoryTrimmer.maxImageCacheCount);
  });

  testWidgets(
    'MemoryLifecycleHost отключает TickerMode в фоне и включает при возврате',
    (tester) async {
      bool? ticking;
      await tester.pumpWidget(
        MaterialApp(
          home: MemoryLifecycleHost(
            child: Builder(
              builder: (context) {
                ticking = TickerMode.valuesOf(context).enabled;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(ticking, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(ticking, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(ticking, isTrue);
    },
  );

  testWidgets('RenderTerminal.clearParagraphCache() безопасно очищает кэш', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 200);
    final key = GlobalKey<TerminalViewState>();
    terminal.write('hello vysh\r\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalView(terminal, key: key)),
      ),
    );
    await tester.pump();

    expect(
      () => key.currentState!.renderTerminal.clearParagraphCache(),
      returnsNormally,
    );
  });
}
