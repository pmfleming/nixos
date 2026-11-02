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
  package = pname: version: { inherit pname version; };
  entry = scope: name: version: { inherit scope name version; };
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
      { name = "wrapper"; }
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
  actual = builtins.fromJSON host.environment.etc."shelllist/application-inventory.json".text;
in
assert
  fixture == {
    schema_version = 1;
    packages = [
      (entry "system" "editor" "1.2")
      (entry "system" "wrapper" null)
      ((entry "system" "google-chrome" "130.0") // { release_source.provider = "chrome-stable"; })
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
