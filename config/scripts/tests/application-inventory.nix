# Independent fixtures for package identity, deduplication and release channels.
{
  lib,
  host,
  machine,
}:
let
  evaluate =
    config:
    builtins.fromJSON
      (import ../../../modules/application-inventory.nix {
        inherit config lib;
      }).environment.etc."shelllist/application-inventory.json".text;
  fixturePath =
    name: version:
    "/nix/store/00000000000000000000000000000000-${name}"
    + lib.optionalString (version != null) "-${version}";
  package = pname: version: {
    inherit pname version;
    outPath = fixturePath pname version;
  };
  entry = scope: name: version: {
    inherit scope name version;
    store_path = fixturePath name version;
    desktop_ids = [ ];
    vendor_tool = null;
    kind = "system";
  };
  customSource = {
    provider = "github";
    repo = "example/editor";
    tag_prefix = "v";
  };
  stableCode = {
    provider = "vscode-stable";
  };
  fixture = evaluate {
    environment.systemPackages = [
      (package "editor" "1.2")
      (package "editor" "1.2")
      {
        name = "wrapper";
        outPath = fixturePath "wrapper" null;
      }
      (package "google-chrome" "130.0")
      ((package "custom-editor" "2.0") // { passthru.shelllistReleaseSource = customSource; })
    ];
    home-manager.users.test.home.packages = [ (package "editor" "1.3") ];
  };
  archive = project: {
    provider = "archive";
    inherit project;
  };
  github = repo: tag_prefix: {
    provider = "github";
    inherit repo tag_prefix;
  };
  expectedSources = {
    acl = archive "acl";
    attr = archive "attr";
    libfido2 = archive "libfido2";
    coreutils-full = archive "coreutils";
    glibc-locales = archive "glibc";
    adwaita-icon-theme = {
      provider = "gnome";
      project = "adwaita-icon-theme";
    };
    adwaita-qt = github "FedoraQt/adwaita-qt" "";
    android-tools = github "nmeum/android-tools" "";
    xz = github "tukaani-project/xz" "v";
  };
  sourceFixture = evaluate {
    environment.systemPackages =
      map (name: package name "1.0") (builtins.attrNames expectedSources)
      ++ [
        (package "unmapped" "1.0")
        ((package "acl" "2.0") // { passthru.shelllistReleaseSource = stableCode; })
      ];
  };
  kernelConfig = {
    environment.systemPackages = [ (package "hyprland" "0.54.0") ];
    boot.kernelPackages.kernel = package "linux-zen" "6.18.9";
  };
  kernelFixture = evaluate kernelConfig;
  disabledKernel = evaluate (
    kernelConfig
    // {
      boot = kernelConfig.boot // { kernel.enable = false; };
    }
  );
  # Decode metadata for assertions only; the generated file retains its package
  # references so Nix still tracks the store paths in the deployed inventory.
  actual = builtins.fromJSON (
    builtins.unsafeDiscardStringContext host.environment.etc."shelllist/application-inventory.json".text
  );
in
assert
  fixture == {
    schema_version = 1;
    packages = [
      (entry "system" "editor" "1.2")
      (entry "system" "wrapper" null)
      (
        (entry "system" "google-chrome" "130.0")
        // {
          release_source.provider = "chrome-stable";
          desktop_ids = [ "google-chrome.desktop" ];
        }
      )
      ((entry "system" "custom-editor" "2.0") // { release_source = customSource; })
      (entry "user:test" "editor" "1.3")
    ];
  };
assert builtins.all (
  p:
  if p.name == "unmapped" then
    !(p ? release_source)
  else if p.version == "2.0" then
    p.release_source == stableCode
  else
    p.release_source == expectedSources.${p.name}
) sourceFixture.packages;
assert
  builtins.length sourceFixture.packages == builtins.length (builtins.attrNames expectedSources) + 2;
assert actual.schema_version == 1;
assert builtins.length kernelFixture.packages == 2;
assert builtins.elem (
  (entry "system" "linux" "6.18.9")
  // {
    store_path = fixturePath "linux-zen" "6.18.9";
    release_source.provider = "kernel-stable";
  }
) kernelFixture.packages;
assert builtins.any (
  p: p.name == "hyprland" && p.release_source == github "hyprwm/Hyprland" "v"
) kernelFixture.packages;
assert builtins.length disabledKernel.packages == 1;
assert builtins.any (
  p:
  p.name == "linux"
  && p.version == host.boot.kernelPackages.kernel.version
  && p.release_source.provider == "kernel-stable"
) actual.packages;
assert builtins.any (
  p: p.name == "hyprland" && p.version == host.programs.hyprland.package.version
) actual.packages;
assert builtins.any (p: p.scope == "system") actual.packages;
assert builtins.any (p: p.scope == "user:${machine.username}") actual.packages;
assert builtins.length actual.packages <= 512;
assert builtins.any (
  p: p.name == "google-chrome" && p.release_source.provider == "chrome-stable"
) actual.packages;
assert builtins.any (
  p: p.name == "vscode" && p.release_source.provider == "vscode-stable"
) actual.packages;
true
