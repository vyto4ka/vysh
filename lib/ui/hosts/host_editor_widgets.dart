part of 'host_editor.dart';

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableSurface(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      pressScale: 0.08,
      borderRadius: BorderRadius.circular(16),
      selectedBorderRadius: BorderRadius.circular(11),
      selected: selected,
      color: color,
      selectedColor: color,
      side: BorderSide.none,
      selectedSide: BorderSide(color: scheme.onSurface, width: 2.5),
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: AnimatedSwitcher(
            duration: AppMotion.duration(context, AppMotion.durationFast),
            switchInCurve: AppMotion.fastSpringCurve,
            switchOutCurve: AppMotion.emphasizedAccelerate,
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: selected
                ? const Icon(
                    Icons.check,
                    key: ValueKey('check'),
                    size: 18,
                    color: Colors.white,
                  )
                : const SizedBox.shrink(key: ValueKey('empty')),
          ),
        ),
      ),
    );
  }
}
