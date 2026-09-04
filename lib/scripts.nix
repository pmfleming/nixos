let
  substitute =
    replacements: text:
    let
      keys = builtins.attrNames replacements;
    in
    builtins.replaceStrings keys (map (key: replacements.${key}) keys) text;

  withPlaceholders = replacements: path: substitute replacements (builtins.readFile path);

in
{
  inherit substitute withPlaceholders;

  mkScriptFrom =
    pkgs: directory:
    {
      name,
      runtimeInputs ? [ ],
      replacements ? { },
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = withPlaceholders replacements (directory + "/${name}.sh");
    };
}
