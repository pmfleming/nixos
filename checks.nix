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
  host = self.nixosConfigurations.${machine.hostName}.config;
  home = host.home-manager.users.${machine.username};
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
  graphics-driver-load = pkgs.linkFarm "graphics-driver-load" [
    {
      name = "64-bit";
      path = import ./lib/graphics-driver-check.nix {
        inherit pkgs;
        drivers = host.hardware.graphics.package;
      };
    }
    {
      name = "32-bit";
      path = import ./lib/graphics-driver-check.nix {
        pkgs = pkgs.pkgsi686Linux;
        drivers = host.hardware.graphics.package32;
      };
    }
  ];
  dbus-discovery =
    mkCheck "dbus-discovery-contract" [ pkgs.python3 pkgs.dbus pkgs.dbus-broker pkgs.systemd ]
      ''
        python3 -B ${./config/scripts}/tests/canonical-dbus.py
        python3 -B ${./config/scripts/tests/dbus-discovery.py} \
          ${host.environment.etc."dbus-1".source} ${host.system.path} \
          ${home.home.path}
      '';
  yazi-clipboard =
    let
      plugin = home.programs.yazi.plugins.yank-to-clip-daemon;
    in
    assert plugin.setup;
    mkCheck "yazi-clipboard-plugin" [ pkgs.lua ] ''
      lua - ${plugin.package}/main.lua <<'LUA'
      local subscribed = false
      ps = { sub = function(event, callback)
        assert(event == "@yank" and type(callback) == "function")
        subscribed = true
      end }
      local plugin = assert(loadfile(arg[1]))()
      plugin:setup()
      assert(subscribed, "Yazi clipboard plugin did not register its yank handler")
      LUA
    '';
  file-associations =
    let
      mime = home.xdg.mimeApps;
      yaziRules = home.programs.yazi.settings.open.prepend_rules;
    in
    assert lib.all
      (
        name:
        mime.defaultApplications.${name} == [ "scratchpad.desktop" ]
        && mime.associations.added.${name} == [ "scratchpad.desktop" ]
      )
      [
        "text/plain"
        "text/x-csrc"
        "text/x-python"
        "text/x-nix"
        "text/x-log"
        "text/markdown"
        "application/json"
        "application/xml"
        "application/yaml"
      ];
    assert lib.all (name: mime.defaultApplications.${name} == [ "zen.desktop" ]) [
      "text/html"
      "application/xhtml+xml"
    ];
    assert lib.all
      (
        name:
        (lib.findFirst (
          rule:
          builtins.elem (rule.mime or "") [
            name
            "text/*"
          ]
        ) { } yaziRules).use == "open"
      )
      [
        "text/html"
        "application/xhtml+xml"
      ];
    assert lib.all (url: (lib.findFirst (rule: (rule.url or "") == url) { } yaziRules).use == "open") [
      "*.html"
      "*.htm"
      "*.xhtml"
    ];
    assert mime.defaultApplications."application/pdf" == [ "okularApplication_pdf.desktop" ];
    assert lib.all (name: !(builtins.hasAttr name mime.defaultApplications)) [
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      "application/vnd.oasis.opendocument.text"
    ];
    assert lib.all (scheme: mime.defaultApplications."x-scheme-handler/${scheme}" == [ "zen.desktop" ])
      [
        "http"
        "https"
      ];
    assert builtins.any (
      rule: (rule.mime or "") == "text/*" && rule.use == "scratchpad"
    ) home.programs.yazi.settings.open.prepend_rules;
    mkCheck "file-associations-contract" [ ] "";
  application-inventory =
    assert import ./config/scripts/tests/application-inventory.nix { inherit lib host machine; };
    mkCheck "application-inventory-contract" [ ] "";
  daemon-modules = inputs.bar-daemon.checks.${system}.modules;
  resource-module = inputs.app-daemon.checks.${system}.modules;
  discovery-module = inputs.nm-daemon.checks.${system}.discoveryModule;
  home-user-unit-files =
    # Immutable managed files should detect collisions, not erase user files.
    assert lib.all (name: !home.home.file.${name}.force) [
      ".pi/agent/extensions/recent-sessions-sidebar"
      ".pi/agent/extensions/worker-dashboard"
      ".pi/agent/extensions/lib"
      ".pi/agent/extensions/instances"
      ".local/bin/pi-instances"
    ];
    assert !(home.xdg.configFile ? "systemd/user/ringboard-server.service");
    assert
      !(home.xdg.configFile ? "systemd/user/graphical-session.target.wants/ringboard-server.service");
    mkCheck "home-user-unit-files" [ pkgs.python3 ] ''
      python3 - ${home.home.activationPackage}/home-files/.config/systemd/user <<'PY'
      import os
      import pathlib
      import sys
      import tempfile

      def broken_links(root):
          def fail(error):
              raise error
          return sorted(
              str(path)
              for directory, directories, files in os.walk(root, followlinks=True, onerror=fail)
              for name in directories + files
              if (path := pathlib.Path(directory, name)).is_symlink() and not path.exists()
          )

      with tempfile.TemporaryDirectory() as directory:
          root = pathlib.Path(directory)
          (root / "valid.service").write_text("[Service]\nExecStart=/bin/true\n")
          wants = root / "graphical-session.target.wants"
          wants.mkdir()
          (wants / "valid.service").symlink_to(root / "valid.service")
          assert not broken_links(root)
          missing = wants / "removed.service"
          missing.symlink_to(root / "missing.service")
          assert broken_links(root) == [str(missing)]

      root = pathlib.Path(sys.argv[1])
      assert root.is_dir(), f"Missing generated user-unit directory: {root}"
      broken = broken_links(root)
      assert not broken, "Dangling Home Manager user-unit links:\n" + "\n".join(broken)
      PY
    '';
  daemon-ownership =
    let
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
          idle = home.services.hypridle.settings;
          hyprlandConfig = home.xdg.configFile."hypr/hyprland.lua".text;
          defaultStack = versions host;
          specialisations = builtins.attrNames host.specialisation;
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
    assert !(home.systemd.user.timers ? build-cache-trim);
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
          --replace-fail '@MONITOR_SCALE@' '1' \
          --replace-fail '@RADIUS_INT@' '1' \
          --replace-fail '@ACCENT_BARE@' '000000' \
          --replace-fail '@BORDER_DIM_BARE@' '000000'
        find ./hypr -type f -name '*.lua' -exec luac -p {} +
        lua ${./config/scripts/tests/hyprland-shortcuts.lua} ./hypr/hyprland.lua
      '';
}
