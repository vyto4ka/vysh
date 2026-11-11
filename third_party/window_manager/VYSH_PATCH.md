# vysh patch to window_manager 0.5.2

Upstream: https://pub.dev/packages/window_manager/versions/0.5.2 (MIT; LICENSE included).
Linux: retain the global button-press emission hook ID and remove it on dispose.
Disconnect per-window callbacks and release the registrar. Without this cleanup,
closing a child Flutter engine leaves a callback pointing at a disposed plugin;
subsequent mouse input can crash the entire multi-window process.
macOS: destroy closes only this plugin's window instead of calling NSApp.terminate,
which would kill all sessions when returning a detached tab.
Windows and the Dart API are unchanged.
