# Как выпустить версию

Релиз (Windows, Linux, PKGBUILD для Arch, DMG для macOS, APK) полностью собирает GitHub Actions: от вас - запись в CHANGELOG, версия и тег.

## 1. CHANGELOG.md

Переименуйте раздел невыпущенной версии и поставьте дату:

```md
## [0.2.0] - 2026-10-15
> Цвета из дотов, свой заголовок окна и Material 3
```

- Строка `> …` сразу под заголовком - название релиза: на GitHub он будет называться «vysh 0.2.0: Цвета из дотов…».
- Группы: `### 🔒 Безопасность`, `### ✨ Новое`, `### 🛠 Улучшено`, `### 🐛 Исправлено`. Пустые не пишите.
- Пишите для пользователя: что стало можно сделать, а не какой файл поменялся.
- Ссылки на файлы репозитория - относительные (`docs/THEMES.md`), на странице релиза они станут полными.

## 2. Версия в pubspec.yaml

```yaml
version: 0.2.0+2   # +N - номер сборки, просто увеличивайте на 1
```

То же самое в `lib/app/version.dart`: `appVersion` и `vyshBuildNumber`. Их показывает «Настройки → О программе».

Номер сборки на Android - это `versionCode`: он должен только расти, иначе новый APK не встанет поверх старого.

## 3. Коммит и тег

```sh
git add -A
git commit -m "vysh 0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

Через 10-15 минут в [Releases](https://github.com/vyto4ka/vysh/releases) появится релиз:

- кнопки скачивания для каждой сборки;
- текст раздела из CHANGELOG;
- блок «Установка» и ссылка на все изменения с прошлой версии;
- сами файлы и манифест SHA256SUMS для встроенного обновления (генерируется CI).

Тег с дефисом (`v0.3.0-beta.1`) публикуется как pre-release и не становится «Latest».

## Arch Linux

CI сам собирает `PKGBUILD` из шаблона `packaging/arch/PKGBUILD.in`: подставляет версию и sha256 Linux-архива и прикладывает файл к релизу. Ссылка `releases/latest/download/PKGBUILD` всегда ведёт на последнюю версию.

Проверить шаблон локально (на Arch):
```sh
TAG=v0.3.3 python3 tools/release/make_pkgbuild.py dist   # нужен dist/vysh-v0.3.3-linux-x64.tar.gz
cd dist && makepkg -si
namcap PKGBUILD
```

### Публикация в AUR (по желанию)

Тогда ставить можно будет через `yay -S vysh-bin` / `paru -S vysh-bin`.

1. Аккаунт на [aur.archlinux.org](https://aur.archlinux.org) и SSH-ключ в профиле.
2. Один раз: `git clone ssh://aur@aur.archlinux.org/vysh-bin.git`
3. На каждый релиз: скачать `PKGBUILD` из релиза в эту папку, затем
   ```sh
   makepkg --printsrcinfo > .SRCINFO
   git add PKGBUILD .SRCINFO && git commit -m "vysh 0.3.3" && git push
   ```

## Android

CI собирает APK под каждую архитектуру (`arm64-v8a`, `armeabi-v7a`, `x86_64`), если в репозитории есть секреты с ключом подписи. Без них сборка Android пропускается с предупреждением, остальное выходит как обычно.

Ключ (`vysh-release.jks`) и пароли в git не кладутся никогда: кто получил ключ, может выпустить «обновление» vysh, которое телефоны примут как настоящее. А если ключ потерять, обновлять уже установленные APK будет нечем.

### Секреты в GitHub

Settings → Secrets and variables → Actions → New repository secret:

| Секрет | Что положить |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | файл `vysh-release.jks` в base64 |
| `ANDROID_STORE_PASSWORD` | `storePassword` из key.properties |
| `ANDROID_KEY_PASSWORD` | `keyPassword` |
| `ANDROID_KEY_ALIAS` | `keyAlias` |

base64 на Windows (cmd), результат в буфер обмена:
```bat
certutil -encodehex -f vysh-release.jks jks.b64 0x40000001 && type jks.b64 | clip && del jks.b64
```
На Linux: `base64 -w0 vysh-release.jks | wl-copy` (или `xclip -sel c`).

### Проверка подписи в CI

APK подписывается схемами v1, v2 и v3 (`android/app/build.gradle.kts`): v1 нужна сторонним установщикам, которые читают сертификат только из неё. После сборки CI проверяет каждый APK через `apksigner` и не выпускает релиз, если нет подписи v1 или v2 или APK подписан debug-ключом.

Чтобы CI сверял и сам сертификат, добавьте переменную (не секрет): Settings → Secrets and variables → Actions → **Variables** → `ANDROID_CERT_SHA256` = SHA-256 сертификата release-ключа, строчными буквами без двоеточий. Для текущего ключа это:

```
4955cb18b7420b605b3da651edeea1c20369b3f3d0fc23d0228d8688711afa4a
```

Посмотреть его у любого APK: `apksigner verify --print-certs файл.apk`, строка `certificate SHA-256 digest`.

### Локальная сборка APK

`android/key.properties` (в .gitignore):
```properties
storePassword=...
keyPassword=...
keyAlias=vysh
storeFile=C:/Users/<вы>/keys/vysh-release.jks
```
Без этого файла `flutter build apk --release` подписывает debug-ключом: для проверки годится, для раздачи нет.

```sh
./tools/build_local.sh apk          # APK по архитектурам, с датой сборки
./tools/build_local.sh apk-universal
```

### Дата сборки

В «О программе» показывается `build N · дата`, если при сборке передан `BUILD_DATE`. Дата - время последнего коммита (в CI по UTC), а не момент сборки: `--dart-define` входит в ключ Dart-сборки, и с текущим временем любой повторный запуск пересобирал бы всё заново (Windows: ~100 с вместо ~20). CI передаёт его сам, локально это делают `tools/build_local.sh`, `tools/build-windows.ps1` и `tools/build_dmg.sh`, вручную так:
```sh
flutter build apk --release --dart-define="BUILD_DATE=$(git log -1 --date=format-local:'%d.%m.%y %H:%M:%S' --format=%cd)"
```

### Кэш CI

Релиз собирается на теге, а кэш, сохранённый на теге, следующему тегу недоступен - только кэш ветки main. Поэтому `warm-cache.yml` собирает Windows и Android в main (на изменения кода и раз в неделю): он сохраняет кэш Flutter SDK, пакетов и Gradle, а релиз его читает. Заодно это проверка, что эти сборки не сломаны, до тега.

## macOS

CI собирает `vysh-<тег>-macos.dmg` на `macos-latest` без каких-либо секретов: приложения Flutter подписываются ad-hoc, и Gatekeeper блокирует первый запуск, пока пользователь не нажмёт «Всё равно открыть» в настройках конфиденциальности (на macOS 12-14 - ПКМ → «Открыть»). Проверка сборки без релиза - workflow `macOS DMG` (`.github/workflows/macos-dmg.yml`): идёт на PR и вручную, DMG остаётся артефактом запуска. Для бесшовного запуска и нотаризации нужен аккаунт Apple Developer и сертификат «Developer ID Application» - добавляется так же, как Android-секреты, когда понадобится.

### Локальная сборка DMG

```sh
./tools/build_dmg.sh    # flutter build macos --release + hdiutil, окно DMG оформляет Finder
```

Требуется полный Xcode: `flutter build macos` вызывает `xcodebuild`, которого нет в Command Line Tools. App Sandbox выключен намеренно: SSH-клиенту нужен `~/.ssh` (ключи по пути из настроек хоста, `id_*` по умолчанию), а песочница пускает только в выбранные файлы и только до перезапуска. Профиль лежит в `~/Library/Application Support/vysh`.

## Если что-то пошло не так

**Сборка упала.** Почините, затем перенесите тег на новый коммит:

```sh
git tag -d v0.2.0 && git push origin :refs/tags/v0.2.0
git tag v0.2.0 && git push origin v0.2.0
```

**Нужно поправить только текст.** Отредактируйте релиз прямо на GitHub (✏️ Edit) - пересобирать не нужно. Посмотреть, что сгенерирует скрипт, можно локально:

```sh
TAG=v0.2.0 REPO=vyto4ka/vysh python3 tools/release/make_notes.py dist
```

(в PowerShell: `$env:TAG="v0.2.0"; $env:REPO="vyto4ka/vysh"; python tools/release/make_notes.py dist`)

## Коммит без сборки

CI проверяет каждый push в `main`. Для правок только в документации добавьте в сообщение `[skip ci]`:

```sh
git commit -m "docs: README [skip ci]"
```
