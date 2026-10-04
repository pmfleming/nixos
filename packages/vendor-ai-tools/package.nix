# Evaluated directly by the updater, never through the host flake or its inputs.
{
  nixpkgs,
  manifestFile,
  piExtensions,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;
  release = builtins.fromJSON (builtins.readFile manifestFile);
  fetch =
    name:
    pkgs.fetchurl {
      inherit (release.assets.${name}) url hash;
    };
  receipt = builtins.toFile "vendor-release.json" (builtins.toJSON release);
  common = {
    inherit (release) version;
    dontStrip = true; # Stripping Bun executables destroys their embedded payload.
    strictDeps = true;
    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.makeWrapper
    ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
      pkgs.openssl
      pkgs.alsa-lib
    ];
    dontBuild = true;
    doInstallCheck = true;
    postInstall = ''
      mkdir -p "$out/share/vendor-ai"
      cp ${receipt} "$out/share/vendor-ai/release.json"
    '';
    preInstallCheck = ''
      export HOME="$TMPDIR/smoke-home"
      mkdir -p "$HOME"
    '';
    installCheckPhase = ''
      runHook preInstallCheck
      ${smoke release.tool}
      runHook postInstallCheck
    '';
  };
  smoke = command: ''
    ${pkgs.coreutils}/bin/timeout 45 "$out/bin/${command}" --version > version.txt
    cat version.txt
    grep -E -- ${lib.escapeShellArg "(^|[^0-9.])${lib.escapeRegex release.version}([^0-9.]|$)"} version.txt
  '';
  piModules = pkgs.importNpmLock.buildNodeModules {
    package = lib.importJSON (fetch "package");
    packageLock =
      let
        original = lib.importJSON (fetch "lock");
      in
      original
      // {
        packages = lib.mapAttrs (
          name: entry:
          entry
          // lib.optionalAttrs (release.npm_integrities ? ${name}) {
            integrity = release.npm_integrities.${name};
          }
        ) original.packages;
      };
    inherit (pkgs) nodejs;
    derivationArgs = {
      npmRebuildFlags = [ "--ignore-scripts" ];
      dontBuild = true;
      # Only published packages; no build/install lifecycle scripts are executed.
      npmFlags = [ "--ignore-scripts" ];
    };
  };
in
assert builtins.elem release.tool [
  "claude"
  "codex"
  "pi"
  "t3"
];
assert pkgs.stdenv.hostPlatform.system == "x86_64-linux";
{
  claude = pkgs.stdenvNoCC.mkDerivation (
    common
    // {
      pname = "vendor-claude-code";
      src = fetch "binary";
      dontUnpack = true;
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/libexec" "$out/bin"
        install -m755 "$src" "$out/libexec/claude"
        makeWrapper "$out/libexec/claude" "$out/bin/claude" \
          --set DISABLE_AUTOUPDATER 1 --set DISABLE_INSTALLATION_CHECKS 1 \
          --set USE_BUILTIN_RIPGREP 0 \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.alsa-lib ]} \
          --prefix PATH : ${
            lib.makeBinPath [
              pkgs.ripgrep
              pkgs.procps
              pkgs.bubblewrap
              pkgs.socat
            ]
          }
        runHook postInstall
      '';
    }
  );

  codex = pkgs.stdenvNoCC.mkDerivation (
    common
    // {
      pname = "vendor-codex";
      src = fetch "archive";
      sourceRoot = ".";
      # The package archive preserves the companion host and resource layout.
      buildInputs = common.buildInputs ++ [
        pkgs.musl
        pkgs.ncurses
      ];
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/libexec/codex" "$out/bin"
        cp -R bin codex-path codex-resources codex-package.json "$out/libexec/codex/"
        for program in codex codex-code-mode-host; do
          makeWrapper "$out/libexec/codex/bin/$program" "$out/bin/$program" \
            --prefix PATH : ${lib.makeBinPath [ pkgs.ripgrep ]}
        done
        runHook postInstall
      '';
    }
  );

  pi = pkgs.stdenvNoCC.mkDerivation (
    common
    // {
      pname = "vendor-pi-coding-agent";
      buildInputs = common.buildInputs ++ [ pkgs.libxcb ];
      dontUnpack = true;
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib" "$out/bin"
        cp -R ${piModules}/node_modules "$out/lib/"
        chmod -R u+w "$out/lib"
        makeWrapper ${pkgs.nodejs}/bin/node "$out/bin/pi" \
          --add-flags "$out/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" \
          --set PI_SKIP_VERSION_CHECK 1 --set-default PI_TELEMETRY 0 \
          --prefix PATH : ${
            lib.makeBinPath [
              pkgs.ripgrep
              pkgs.fd
            ]
          }
        runHook postInstall
      '';
      postInstallCheck = ''
        # Gate this tool alone on the exact extension snapshot deployed with the worker.
        cp -R ${
          builtins.path {
            path = piExtensions;
            name = "pi-extensions";
          }
        } ./pi-extensions
        chmod -R u+w ./pi-extensions
        ln -s "$out/lib/node_modules" node_modules
        ${pkgs.typescript}/bin/tsc --project ./pi-extensions/tsconfig.json
        ${pkgs.nodejs}/bin/node --experimental-strip-types --test ./pi-extensions/tests/*.test.ts
      '';
    }
  );

  t3 = pkgs.stdenvNoCC.mkDerivation (
    common
    // {
      pname = "vendor-t3code";
      src = fetch "archive";
      nativeBuildInputs = common.nativeBuildInputs ++ [ pkgs.dpkg ];
      buildInputs =
        common.buildInputs
        ++ (with pkgs; [
          musl
          glib
          gtk3
          nss
          nspr
          atk
          at-spi2-atk
          at-spi2-core
          cups
          dbus
          expat
          libdrm
          libxkbcommon
          mesa
          libGL
          pango
          cairo
          systemd
          libsecret
          libX11
          libXcomposite
          libXdamage
          libXext
          libXfixes
          libXrandr
          libxcb
        ]);
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/libexec/t3" "$out/bin"
        cp -R . "$out/libexec/t3/"
        dpkg-deb -x ${fetch "desktop"} desktop
        cp -R "desktop/opt/T3 Code (Alpha)" "$out/libexec/t3-desktop"
        # Do not bundle an installation mechanism or a setuid sandbox helper.
        rm -f "$out/libexec/t3-desktop/chrome-sandbox" \
          "$out/libexec/t3-desktop/resources/app-update.yml"
        makeWrapper "$out/libexec/t3/t3" "$out/bin/t3" \
          --set T3CODE_DISABLE_AUTO_UPDATE true
        makeWrapper "$out/libexec/t3-desktop/t3code" "$out/bin/t3code-desktop" \
          --set T3CODE_DISABLE_AUTO_UPDATE true
        # Deliberately do not prepend a pinned Codex: use the independent active tool.
        runHook postInstall
      '';
      postInstallCheck = ''
        # Exercise Electron's loader without starting a desktop or contacting a provider.
        ELECTRON_RUN_AS_NODE=1 ${pkgs.coreutils}/bin/timeout 45 \
          "$out/libexec/t3-desktop/t3code" -e 'if (!process.versions.electron) process.exit(1)'
      '';
    }
  );
}
.${release.tool}
