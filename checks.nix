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
  dbus-discovery =
    let
      host = self.nixosConfigurations.${machine.hostName}.config;
    in
    mkCheck "dbus-discovery-contract" [ pkgs.python3 pkgs.dbus pkgs.dbus-broker pkgs.systemd ] ''
      python3 -B ${./config/scripts}/tests/canonical-dbus.py
      python3 -B ${./config/scripts/tests/dbus-discovery.py} \
        ${host.environment.etc."dbus-1".source} ${host.system.path} \
        ${host.home-manager.users.${machine.username}.home.path}
    '';
  application-inventory =
    let
      fixture =
        (import ./modules/application-inventory.nix {
          inherit lib;
          config = {
            environment.systemPackages = [
              {
                pname = "editor";
                version = "1.2";
              }
              {
                pname = "editor";
                version = "1.2";
              }
              { name = "wrapper"; }
              {
                pname = "google-chrome";
                version = "130.0";
              }
              {
                pname = "custom-editor";
                version = "2.0";
                passthru.shelllistReleaseSource = {
                  provider = "github";
                  repo = "example/editor";
                  tag_prefix = "v";
                };
              }
            ];
            home-manager.users.test.home.packages = [
              {
                pname = "editor";
                version = "1.3";
              }
            ];
          };
        }).environment.etc."shelllist/application-inventory.json".text;
      # Exercise package-name aliases, catalogue identities and override priority
      # independently of the packages currently installed on this host.
      expectedSources = {
        acl = {
          provider = "archive";
          project = "acl";
        };
        attr = {
          provider = "archive";
          project = "attr";
        };
        libfido2 = {
          provider = "archive";
          project = "libfido2";
        };
        coreutils-full = {
          provider = "archive";
          project = "coreutils";
        };
        glibc-locales = {
          provider = "archive";
          project = "glibc";
        };
        adwaita-icon-theme = {
          provider = "gnome";
          project = "adwaita-icon-theme";
        };
        adwaita-qt = {
          provider = "github";
          repo = "FedoraQt/adwaita-qt";
          tag_prefix = "";
        };
        android-tools = {
          provider = "github";
          repo = "nmeum/android-tools";
          tag_prefix = "";
        };
        xz = {
          provider = "github";
          repo = "tukaani-project/xz";
          tag_prefix = "v";
        };
      };
      sourceFixture =
        builtins.fromJSON
          (import ./modules/application-inventory.nix {
            inherit lib;
            config.environment.systemPackages =
              (map (pname: {
                inherit pname;
                version = "1.0";
              }) (builtins.attrNames expectedSources))
              ++ [
                {
                  pname = "unmapped";
                  version = "1.0";
                }
                {
                  pname = "acl";
                  version = "2.0";
                  passthru.shelllistReleaseSource = {
                    provider = "vscode-stable";
                  };
                }
              ];
          }).environment.etc."shelllist/application-inventory.json".text;
      actual =
        builtins.fromJSON
          self.nixosConfigurations.${machine.hostName}.config.environment.etc."shelllist/application-inventory.json".text;
    in
    assert
      (builtins.fromJSON fixture) == {
        schema_version = 1;
        packages = [
          {
            scope = "system";
            name = "editor";
            version = "1.2";
          }
          {
            scope = "system";
            name = "wrapper";
            version = null;
          }
          {
            scope = "system";
            name = "google-chrome";
            version = "130.0";
            release_source = {
              provider = "chrome-stable";
            };
          }
          {
            scope = "system";
            name = "custom-editor";
            version = "2.0";
            release_source = {
              provider = "github";
              repo = "example/editor";
              tag_prefix = "v";
            };
          }
          {
            scope = "user:test";
            name = "editor";
            version = "1.3";
          }
        ];
      };
    assert builtins.all (
      p:
      if p.name == "unmapped" then
        !(p ? release_source)
      else if p.version == "2.0" then
        p.release_source == { provider = "vscode-stable"; }
      else
        p.release_source == expectedSources.${p.name}
    ) sourceFixture.packages;
    assert
      builtins.length sourceFixture.packages == builtins.length (builtins.attrNames expectedSources) + 2;
    assert actual.schema_version == 1;
    assert builtins.any (p: p.scope == "system") actual.packages;
    assert builtins.any (p: p.scope == "user:${machine.username}") actual.packages;
    assert builtins.length actual.packages <= 512;
    assert builtins.any (
      p: p.name == "google-chrome" && p.release_source.provider == "chrome-stable"
    ) actual.packages;
    assert builtins.any (
      p: p.name == "vscode" && p.release_source.provider == "vscode-stable"
    ) actual.packages;
    mkCheck "application-inventory-contract" [ ] "";
  daemon-modules = inputs.bar-daemon.checks.${system}.modules;
  resource-module = inputs.app-daemon.checks.${system}.modules;
  discovery-module = inputs.nm-daemon.checks.${system}.discoveryModule;
  daemon-ownership =
    let
      host = self.nixosConfigurations.${machine.hostName}.config;
      home = host.home-manager.users.${machine.username};
      headless =
        (self.nixosConfigurations.${machine.hostName}.extendModules {
          modules = [
            { home-manager.users.${machine.username}.programs.shelllist.enable = lib.mkForce false; }
          ];
        }).config.home-manager.users.${machine.username};
    in
    assert home.services.bar-daemon.enable;
    assert headless.services.bar-daemon.enable;
    assert !(headless.systemd.user.services ? shelllist);
    assert
      home.systemd.user.services.bar-daemon.Service == headless.systemd.user.services.bar-daemon.Service;
    assert home.systemd.user.services.hypridle.Service.Type == "notify";
    assert lib.hasPrefix "${home.services.bar-daemon.package}/bin/bar-daemon idle" (
      lib.head home.systemd.user.services.hypridle.Service.ExecStart
    );
    assert builtins.elem "BAR_DAEMON_DISPLAY_CONTROL=1"
      home.systemd.user.services.bar-daemon.Service.Environment;
    assert builtins.elem "BAR_DAEMON_YOUTUBE_METADATA=1"
      home.systemd.user.services.bar-daemon.Service.Environment;
    assert host.services.bar-daemon.batteryHelper.enable;
    assert host.services.resolved.settings.Resolve.MulticastDNS == "true";
    assert host.networking.networkmanager.connectionConfig."connection.mdns" == -1;
    assert host.networking.networkmanager.enable;
    assert
      toString host.networking.networkmanager.package
      == toString inputs.nm-daemon.packages.${system}.networkmanagerStable;
    assert
      toString home.xdg.configFile."systemd/user/nm-daemon.service".source
      == "${inputs.nm-daemon.packages.${system}.default}/share/systemd/user/nm-daemon.service";
    pkgs.runCommand "daemon-ownership-contract" { } "touch $out";
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
        python3 -B ${./config/scripts}/tests/rebuild-report.py
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
  # Includes Rust location policy/retry and private D-Bus boundary tests.
  location-timezone = inputs.bar-daemon.checks.${pkgs.stdenv.hostPlatform.system}.default;
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
  build-cache-trim =
    let
      host = self.nixosConfigurations.${machine.hostName}.config;
      service = host.systemd.services.build-cache-trim;
    in
    assert service.serviceConfig.User == machine.username;
    assert service.serviceConfig.RemainAfterExit;
    assert lib.hasSuffix "/bin/true" service.serviceConfig.ExecStart;
    assert lib.hasSuffix "/bin/build-cache-trim" service.serviceConfig.ExecStop;
    assert service.serviceConfig.TimeoutStopSec == "60s";
    assert service.serviceConfig.TimeoutStopFailureMode == "kill";
    assert lib.all (path: builtins.elem path service.unitConfig.RequiresMountsFor) (
      host.services.build-cache-trim.workspaceRoots ++ host.services.build-cache-trim.repositories
    );
    assert builtins.elem "systemd-logind.service" service.before;
    assert !(builtins.elem "user.slice" service.before);
    assert host.services.build-cache-trim.sharedCaches.enable;
    assert builtins.elem "${machine.homeDirectory}/.cache/rqlens/helpers"
      service.unitConfig.RequiresMountsFor;
    assert builtins.elem "${machine.homeDirectory}/.npm/_cacache" service.unitConfig.RequiresMountsFor;
    assert
      service.serviceConfig.ReadWritePaths == map (path: "-" + path) service.unitConfig.RequiresMountsFor;
    assert host.services.build-cache-trim.workspaceRoots != [ ];
    assert !service.restartIfChanged && !service.stopIfChanged;
    assert !(host.systemd.timers ? build-cache-trim);
    assert !(host.home-manager.users.${machine.username}.systemd.user.timers ? build-cache-trim);
    (inputs.update-daemon.lib.mkBuildCachePackage {
      inherit pkgs;
      repositories = [ ];
    }).tests;
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
