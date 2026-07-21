let
  substitute =
    replacements: text:
    let
      keys = builtins.attrNames replacements;
    in
    builtins.replaceStrings keys (map (key: replacements.${key}) keys) text;

  withPlaceholders = replacements: path: substitute replacements (builtins.readFile path);

  mkShellApplication =
    pkgs:
    {
      name,
      runtimeInputs ? [ ],
      replacements ? { },
      path,
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = withPlaceholders replacements path;
    };
in
{
  inherit substitute withPlaceholders mkShellApplication;

  mkScriptFrom =
    pkgs: directory: attrs:
    mkShellApplication pkgs (attrs // { path = directory + "/${attrs.name}.sh"; });
}
