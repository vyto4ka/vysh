{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  copyDesktopItems,
  makeDesktopItem,
  gtk3,
  glib,
  libsecret,
  json-glib,
  zlib,
  libepoxy,
  fontconfig,
  libglvnd,
  vulkan-loader,
  wayland,
  libxkbcommon,
  libx11,
  libxcursor,
  libxrandr,
  libxi,
  libxinerama,
  libxext,
  xdg-utils,
  util-linux,
  coreutils,
  which,
  iputils,
  traceroute,
  # Позволяет в CI и при локальной проверке подставить локальный tar.gz
  # (имена не должны пересекаться с пакетами nixpkgs вроде pkgs.src).
  releaseArchive ? null,
  releaseVersion ? null,
}:

let
  release = lib.importJSON ./release.json;
  finalVersion = if releaseVersion != null then releaseVersion else release.version;
  finalSrc =
    if releaseArchive != null then
      releaseArchive
    else
      fetchurl {
        url = release.url;
        hash = release.hash;
      };
  runtimeBins = [
    fontconfig
    glib.bin
    xdg-utils
    util-linux
    coreutils
    which
    iputils
    traceroute
  ];
in
stdenv.mkDerivation {
  pname = "vysh";
  version = finalVersion;
  src = finalSrc;

  # Архив без корневой папки (сразу vysh, lib/, data/, LICENSE).
  unpackPhase = ''
    runHook preUnpack
    mkdir -p source
    tar -xzf "$src" -C source
    runHook postUnpack
  '';
  sourceRoot = "source";

  # strip повреждает AOT-снапшот Dart в lib/libapp.so.
  dontStrip = true;
  # Оборачиваем бинарник вручную в postFixup, чтобы не плодить двойные обёртки.
  dontWrapGApps = true;

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
    copyDesktopItems
  ];

  buildInputs = [
    gtk3
    glib
    libsecret
    json-glib
    zlib
    libepoxy
    stdenv.cc.cc.lib
  ];

  # Библиотеки, загружаемые через dlopen движком Flutter, GTK и плагинами.
  runtimeDependencies = [
    libglvnd
    vulkan-loader
    wayland
    libxkbcommon
    libx11
    libxcursor
    libxrandr
    libxi
    libxinerama
    libxext
  ];

  # Сохраняем поиск бандловых .so (libflutter_pty.so, libapp.so и др.) рядом с бинарником.
  appendRunpaths = [ "$ORIGIN/lib" ];

  # libdartjni.so попадает в Linux-бандл транзитивно из Android-зависимости jni;
  # на Linux JVM не используется.
  autoPatchelfIgnoreMissingDeps = [ "libjvm.so" ];

  desktopItems = [
    (makeDesktopItem {
      # Имя файла = APPLICATION_ID в linux/CMakeLists.txt (иконка на Wayland).
      name = "dev.vysh.vysh";
      desktopName = "vysh";
      genericName = "SSH Client";
      comment = "Minimal SSH manager with tabs, terminal and SFTP";
      exec = "vysh";
      icon = "vysh";
      terminal = false;
      categories = [
        "Network"
        "RemoteAccess"
        "System"
        "TerminalEmulator"
      ];
      keywords = [
        "ssh"
        "sftp"
        "terminal"
      ];
      startupWMClass = "dev.vysh.vysh";
    })
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec/vysh" "$out/bin"
    cp -r vysh lib data "$out/libexec/vysh/"
    chmod 755 "$out/libexec/vysh/vysh"

    if [ -f LICENSE ]; then
      install -Dm644 LICENSE "$out/share/licenses/vysh/LICENSE"
    fi

    install -Dm644 \
      "$out/libexec/vysh/data/flutter_assets/assets/icon/vysh_256.png" \
      "$out/share/icons/hicolor/256x256/apps/vysh.png"

    runHook postInstall
  '';

  # --suffix PATH (а не --prefix): не перекрываем /run/wrappers/bin/ping с cap_net_raw
  # и пользовательский профиль в локальном терминале vysh.
  postFixup = ''
    makeWrapper "$out/libexec/vysh/vysh" "$out/bin/vysh" \
      "''${gappsWrapperArgs[@]}" \
      --suffix PATH : "${lib.makeBinPath runtimeBins}"
  '';

  meta = {
    description = "Minimal SSH manager with tabs, terminal and SFTP (Material 3)";
    homepage = "https://github.com/vyto4ka/vysh";
    changelog = "https://github.com/vyto4ka/vysh/blob/v${finalVersion}/CHANGELOG.md";
    license = lib.licenses.gpl3Plus;
    mainProgram = "vysh";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
