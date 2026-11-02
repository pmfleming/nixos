# One routing policy for desktop MIME defaults and Yazi's ordered opener rules.
{ lib, ... }:
let
  # MIME defaults have no text/* wildcard. Explicit markup/source types also
  # cover clients that do not inherit the text/plain association.
  textMimeTypes = [
    "text/plain"
    "text/markdown"
    "text/x-markdown"
    "text/x-rst"
    "text/asciidoc"
    "text/css"
    "text/csv"
    "text/tab-separated-values"
    "text/xml"
    "text/yaml"
    "text/x-yaml"
    "text/javascript"
    "text/rust"
    "text/org"
    "text/sgml"
    "application/json"
    "application/json5"
    "application/ld+json"
    "application/xml"
    "application/yaml"
    "application/x-yaml"
    "application/toml"
    "application/javascript"
    "application/sql"
    "application/x-shellscript"
    "application/x-fishscript"
    "application/x-nuscript"
    "application/x-perl"
    "application/x-ruby"
    "application/x-php"
  ]
  ++ map (name: "text/x-${name}") [
    "c"
    "csrc"
    "chdr"
    "c++src"
    "c++hdr"
    "csharp"
    "cmake"
    "makefile"
    "meson"
    "nix"
    "python"
    "python3"
    "java"
    "kotlin"
    "go"
    "rust"
    "lua"
    "qml"
    "shellscript"
    "sh"
    "javascript"
    "typescript"
    "sass"
    "scss"
    "tex"
    "bibtex"
    "texinfo"
    "opml+xml"
    "log"
    "readme"
    "patch"
    "diff"
    "ini"
    "config"
    "dbus-service"
    "systemd-unit"
    "desktop"
  ];
  browserMimeTypes = [
    "text/html"
    "application/xhtml+xml"
  ];
  textApplications = lib.genAttrs textMimeTypes (_: [ "scratchpad.desktop" ]);
  rules =
    field: values: use:
    map (value: {
      ${field} = value;
      inherit use;
    }) values;
in
{
  xdg.mimeApps = {
    enable = true;
    associations.added = textApplications;
    defaultApplications =
      textApplications
      // lib.genAttrs browserMimeTypes (_: "zen.desktop")
      // {
        "application/pdf" = "okularApplication_pdf.desktop";
        "inode/directory" = "yazi.desktop";
        "x-scheme-handler/file" = "yazi.desktop";
        "x-scheme-handler/http" = "zen.desktop";
        "x-scheme-handler/https" = "zen.desktop";
      };
  };
  # Browser rules must win over the text/* Scratchpad fallback.
  programs.yazi.settings.open.prepend_rules =
    rules "url" [ "*.html" "*.htm" "*.xhtml" ] "open"
    ++ rules "mime" browserMimeTypes "open"
    ++ rules "url" [ "*.md" "*.markdown" ] "scratchpad"
    ++ rules "mime" ([ "text/*" ] ++ textMimeTypes) "scratchpad"
    ++ rules "mime" [ "image/*" ] "satty";
}
