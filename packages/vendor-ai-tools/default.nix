{
  pkgs,
  piExtensions,
  fallbacks,
  username,
}:
let
  state = "/var/lib/nixos-ai-tools/vendor";
  notify = pkgs.writeShellScript "notify-ai-tools" ''
    uid=$(${pkgs.coreutils}/bin/id -u ${pkgs.lib.escapeShellArg username})
    bus="/run/user/$uid/bus"
    test -S "$bus" || exit 1
    exec ${pkgs.util-linux}/bin/runuser -u ${pkgs.lib.escapeShellArg username} -- \
      ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      ${pkgs.libnotify}/bin/notify-send --urgency=critical --app-name=nixos-ai-tools "$@"
  '';
  config = pkgs.writeText "vendor-ai-tools-config.json" (
    builtins.toJSON {
      inherit state;
      jobs = "/var/lib/nixos-delayed-updates-v2/jobs";
      legacy = "/var/lib/nixos-ai-tools/current";
      bootstrap = {
        claude = "/run/current-system/sw/bin/claude";
        codex = "/etc/profiles/per-user/${username}/bin/codex";
        pi = "/run/current-system/sw/bin/pi";
        t3 = "/run/current-system/sw/bin/t3";
      };
      nixpkgs = "${pkgs.path}";
      recipe = "${./package.nix}";
      extensions = "${piExtensions}";
      nix_build = "${pkgs.nix}/bin/nix-build";
      notify_command = [ "${notify}" ];
    }
  );
  updater = pkgs.writeShellScriptBin "ai-tools" ''
    # systemd does not inherit an interactive shell's CA environment.
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    exec ${pkgs.python3}/bin/python3 ${./updater.py} --config ${config} "$@"
  '';
  launch =
    tool: command: fallback:
    pkgs.writeShellScriptBin command ''
      # Stable indirection: new launches see atomic per-tool activation immediately.
      candidate=${state}/${tool}/current/bin/${command}
      if test -x "$candidate"; then exec "$candidate" "$@"; fi
      legacy=/var/lib/nixos-ai-tools/current/bin/${command}
      if test -x "$legacy"; then exec "$legacy" "$@"; fi
      exec ${fallback}/bin/${command} "$@"
    '';
in
{
  inherit updater;
  launchers = pkgs.symlinkJoin {
    name = "vendor-ai-tool-launchers";
    paths = [
      (launch "claude" "claude" fallbacks.claude-code)
      (launch "codex" "codex" fallbacks.codex)
      (launch "codex" "codex-code-mode-host" fallbacks.codex)
      (launch "pi" "pi" fallbacks.pi-coding-agent)
      (launch "t3" "t3" fallbacks.t3code)
      (launch "t3" "t3code-desktop" fallbacks.t3code)
    ];
  };
  tests = pkgs.runCommand "vendor-ai-tools-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -R ${./.} ./source
    chmod -R u+w source
    python3 -B -m unittest discover -s source/tests -v
    ${pkgs.coreutils}/bin/env -i PATH=/missing ${updater}/bin/ai-tools status --json > /dev/null
    touch "$out"
  '';
}
