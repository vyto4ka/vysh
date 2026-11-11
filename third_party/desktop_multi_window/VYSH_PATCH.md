# desktop_multi_window 0.3.1

Source: https://pub.dev/packages/desktop_multi_window/versions/0.3.1
Upstream license is preserved in LICENSE.

Local changes:
- Removed the monorepo-only `resolution: workspace` from pubspec.yaml.
- Linux and Windows child Flutter engines inherit the owner's `VYSH_RENDERER`
  selection. Without this, Flutter 3.47 creates an Impeller child alongside a
  Skia owner and can produce a blank window/OpenGL context errors.

- Windows child engines use the same separate UI thread policy as the main runner.

Dart API and channel protocol are unchanged. The runner registers the app's
plugins for every child engine, as required by the upstream integration guide.
