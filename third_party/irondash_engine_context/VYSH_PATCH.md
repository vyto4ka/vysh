# irondash_engine_context для vysh

Копия пакета с pub.dev (лицензия в LICENSE) с правками в `cargokit/gradle/plugin.gradle`:
`project.exec {}` убран в Gradle 9, сборка APK падала с «Could not find method exec()».
Команда теперь запускается через `ExecOperations`.

Вторая правка - `android/build.gradle`: `compileSdkVersion` 36 вместо 31, иначе
сборка APK падает на проверке AAR (device_info_plus и androidx требуют 33-36).
minSdk и поведение на устройстве это не меняет.

Третья правка - `macos/Classes/EngineContextPlugin.m`: проверка `context != nil`
в `getFlutterView:`, `getTextureRegistry:` и `getBinaryMessenger:`, чтобы при
раннем обращении из дочернего движка до выполнения `dispatch_async` не было
разыменования NULL.

Rust-исходники не тронуты, поэтому хеш крейта прежний и cargokit по-прежнему
скачивает готовые бинарники, Rust ставить не нужно.

Подключается через `dependency_overrides` в pubspec.yaml. Когда выйдет версия
с поддержкой Gradle 9, актуальным Android SDK и проверкой `context != nil`
на macOS без обязательного Rust, папку можно удалить.
