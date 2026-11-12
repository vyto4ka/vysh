import 'package:flutter/material.dart';

/// Круглый знак приложения. Масштаб убирает прозрачные поля исходного PNG.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) => ClipOval(
    child: Transform.scale(
      scale: 1.12,
      child: Image.asset(
        'assets/icon/vysh_256.png',
        width: size,
        height: size,
        cacheWidth: (size * 1.12 * MediaQuery.devicePixelRatioOf(context))
            .ceil(),
        filterQuality: FilterQuality.medium,
      ),
    ),
  );
}
