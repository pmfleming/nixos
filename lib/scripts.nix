let
  withPlaceholders = replacements: path:
    let keys = builtins.attrNames replacements;
    in builtins.replaceStrings keys (map (key: replacements.${key}) keys) (builtins.readFile path);
in
{
  inherit withPlaceholders;

  mkShellApplication = pkgs: { name, runtimeInputs ? [], replacements ? {}, path }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = withPlaceholders replacements path;
    };
}
