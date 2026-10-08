# Deployment gates live together; flake.nix only wires inputs and host outputs.
{
  self,
  inputs,
  pkgs,
  machine,
  unstablePkgs,
  updateWorker,
  vendorAiTools,
}:
let
  inherit (pkgs) lib;
  inherit (machine) system;
  # Filter before interpolation: ${self}/subdir would still depend on the
  # entire flake (including the disposable local-input lock).
  nixSources = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
  };
  displaySources = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./home.nix
      ./config/hypr
    ];
  };
  configSources = lib.fileset.toSource {
    root = ./config;
    fileset = lib.fileset.fileFilter (
      file: file.hasExt "json" || file.hasExt "jsonc" || file.hasExt "lua"
    ) ./config;
  };
  mkCheck =
    name: nativeBuildInputs: script:
    pkgs.runCommand name { inherit nativeBuildInputs; } (script + "\ntouch $out\n");
in
# `flake check` is not recursive: retain the complete consumer contract matrix.
lib.mapAttrs' (
  name: value: lib.nameValuePair "shelllist-${name}" value
) inputs.shelllist.checks.${system}
// {
  rebuild-sources =
    mkCheck "rebuild-source-identity-tests"
      (with pkgs; [
        bash
        coreutils
        findutils
        git
        jq
        python3
        util-linux
      ])
      ''
        python3 ${./config/scripts/tests/rebuild-sources.py} ${./config/scripts} \
          ${updateWorker.testDriver} ${updateWorker.testConfig}
      '';
  nix =
    mkCheck "nix-quality-check"
      (with pkgs; [
        deadnix
        findutils
        nixfmt
        statix
      ])
      ''
        find ${nixSources} -type f -name '*.nix' -exec nixfmt --check {} +
        deadnix --fail ${nixSources}
        statix check ${nixSources}
      '';
  shellcheck = mkCheck "shellcheck" [ pkgs.shellcheck ] ''
    find ${./config/scripts} -type f -name '*.sh' \
      -exec shellcheck -s bash -x -e SC1091 {} +
  '';
  sleep-recovery =
    let
      base = self.nixosConfigurations.${machine.hostName}.config;
      versions = config: {
        kernel = config.boot.kernelPackages.kernel.version;
        hyprland = config.programs.hyprland.package.version;
        portal = config.programs.hyprland.portalPackage.version;
        mesa = config.hardware.graphics.package.version;
        mesa32 = config.hardware.graphics.package32.version;
        aquamarine =
          (lib.findFirst (
            p: (p.pname or "") == "aquamarine"
          ) (throw "Hyprland must link Aquamarine") config.programs.hyprland.package.buildInputs).version;
      };
      fixture = pkgs.writeText "sleep-recovery.json" (
        builtins.toJSON {
          idle = base.home-manager.users.${machine.username}.services.hypridle.settings;
          hyprlandConfig =
            base.home-manager.users.${machine.username}.xdg.configFile."hypr/hyprland.lua".text;
          defaultStack = versions base;
          specialisations = builtins.attrNames base.specialisation;
        }
      );
    in
    mkCheck "sleep-recovery-tests" [ pkgs.python3 ] ''
      python3 ${./config/scripts/tests/sleep-recovery.py} ${fixture}
    '';
  display-layout-compatibility = mkCheck "display-layout-compatibility" [ pkgs.bash pkgs.gnugrep ] ''
    bash ${./config/scripts/tests/display-layout-compatibility.sh} ${displaySources}
  '';
  deployment-lock =
    mkCheck "deployment-lock-tests"
      (with pkgs; [
        bash
        coreutils
        jq
        util-linux
      ])
      ''
        bash ${./config/scripts/tests/deployment-lock.sh} \
          ${./config/scripts} ${updateWorker.testDriver} ${updateWorker.testConfig}
      '';
  updater-state = updateWorker.tests;
  # Catch npm lock/hash drift before the system deployment build.
  ts-react-quality-lens = inputs.ts-react-quality-lens.packages.${system}.default;
  vendor-ai-tools = vendorAiTools.tests;
  generation-retention =
    mkCheck "generation-retention-tests"
      (with pkgs; [
        bash
        coreutils
        gawk
        util-linux
      ])
      ''
        bash ${./config/scripts/tests/prune-nixos-generations.sh} \
          ${./config/scripts}/prune-nixos-generations.sh
      '';
  pi-extensions =
    mkCheck "pi-extension-tests"
      (with pkgs; [
        nodejs
        typescript
      ])
      ''
        cp -R ${./config/pi} ./pi
        chmod -R u+w ./pi

        vendor=${unstablePkgs.pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules
        mkdir -p node_modules/@earendil-works
        for entry in "$vendor"/*; do
          name="$(basename "$entry")"
          if [ "$name" != @earendil-works ]; then
            ln -s "$entry" "node_modules/$name"
          fi
        done
        for entry in "$vendor/@earendil-works"/*; do
          ln -s "$entry" "node_modules/@earendil-works/$(basename "$entry")"
        done
        ln -s ${unstablePkgs.pi-coding-agent}/lib/node_modules/pi-monorepo \
          node_modules/@earendil-works/pi-coding-agent

        tsc --project ./pi/tsconfig.json
        node --experimental-strip-types --test ./pi/tests/*.test.ts
      '';
  config-files =
    mkCheck "desktop-config-tests"
      (with pkgs; [
        lua
        (python3.withPackages (pythonPackages: [ pythonPackages.json5 ]))
      ])
      ''
        python - <<'PY'
        import json
        from pathlib import Path

        import json5

        root = Path("${configSources}")
        for path in root.rglob("*.json"):
            with path.open(encoding="utf-8") as source:
                json.load(source)
        for path in root.rglob("*.jsonc"):
            with path.open(encoding="utf-8") as source:
                json5.load(source)
        PY

        cp -R ${configSources}/hypr ./hypr
        chmod -R u+w ./hypr
        substituteInPlace ./hypr/hyprland.lua \
          --replace-fail '@UWSM_APP@' '/bin/true' \
          --replace-fail '@SCRATCHPAD@' '/bin/true' \
          --replace-fail '@MONITOR_SCALE@' '1' \
          --replace-fail '@RADIUS_INT@' '1' \
          --replace-fail '@ACCENT_BARE@' '000000' \
          --replace-fail '@BORDER_DIM_BARE@' '000000'
        find ./hypr -type f -name '*.lua' -exec luac -p {} +
        lua ${./config/scripts/tests/hyprland-shortcuts.lua} ./hypr/hyprland.lua
      '';
}
