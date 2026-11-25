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
  xorg ? null,
  libx11 ? xorg.libX11,
  libxcursor ? xorg.libXcursor,
  libxrandr ? xorg.libXrandr,
  libxi ? xorg.libXi,
  libxinerama ? xorg.libXinerama,
  libxext ? xorg.libXext,
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
  changelogRef =
    if builtins.match "[0-9]+\\.[0-9]+.*" finalVersion != null then
      "v${finalVersion}"
    else
      "main";
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

  # Абсолютный путь к бандловым .so нужен в RUNPATH не только у самого vysh,
  # но и у libflutter_linux_gtk.so (откуда Dart вызывает dlopen("libflutter_pty.so")
  # без DT_NEEDED). С "$ORIGIN/lib" для файлов внутри lib/ получался несуществующий lib/lib.
  appendRunpaths = [ "${placeholder "out"}/libexec/vysh/lib" ];

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

    # libdartjni.so попадает в Linux-бандл транзитивно из Android-зависимости jni
    # и требует libjvm.so, но на Linux JVM не используется.
    rm -f "$out/libexec/vysh/lib/libdartjni.so"

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
    changelog = "https://github.com/vyto4ka/vysh/blob/${changelogRef}/CHANGELOG.md";
    license = lib.licenses.gpl3Plus;
    mainProgram = "vysh";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
