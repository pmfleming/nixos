let
  palette = {
    bg = "#101418";
    muted = "#69727d";
    text = "#d7dee8";
    subtext = "#aeb8c4";
    accent = "#2f8cff";
    accentBare = "2f8cff";

    black = "#000000";
    white = "#ffffff";
    foreground = "#f5f5f5";
    borderDim = "#141b22";
    selectedBg = "#26455f";
    accentDark = "#14508f";
    dangerDark = "#8f2d2d";
    success = "#3fb950";
    danger = "#f05a5a";
    warning = "#f59e0b";
  };

  fonts = {
    mono = "JetBrainsMono Nerd Font";
    monoNerd = "JetBrainsMono Nerd Font Mono";
    sans = "Noto Sans";
    serif = "Noto Serif";
  };

  ui = {
    radius = "3px";
    fontSizeInt = 12;
    fontSize = "12";
    rofiWidth = "36%";
    rofiLines = "12";
    scrollbarWidth = "5px";
  };

  colorBare = color: builtins.substring 1 6 color;

  themeTokens = {
    "@BG@" = palette.bg;
    "@BG_BARE@" = colorBare palette.bg;
    "@MUTED@" = palette.muted;
    "@TEXT@" = palette.text;
    "@TEXT_BARE@" = colorBare palette.text;
    "@SUBTEXT@" = palette.subtext;
    "@SUBTEXT_BARE@" = colorBare palette.subtext;
    "@ACCENT@" = palette.accent;
    "@ACCENT_BARE@" = palette.accentBare;
    "@ACCENT_RGB@" = "47, 140, 255";
    "@FOREGROUND@" = palette.foreground;
    "@FOREGROUND_BARE@" = colorBare palette.foreground;
    "@BLACK@" = palette.black;
    "@WHITE@" = palette.white;
    "@BORDER_DIM@" = palette.borderDim;
    "@SELECTED_BG_BARE@" = colorBare palette.selectedBg;
    "@SUCCESS@" = palette.success;
    "@DANGER@" = palette.danger;
    "@DANGER_BARE@" = colorBare palette.danger;
    "@WARNING@" = palette.warning;
    "@RADIUS@" = ui.radius;
    "@FONT_MONO@" = fonts.mono;
    "@FONT_MONO_NERD@" = fonts.monoNerd;
    "@FONT_SIZE@" = ui.fontSize;
    "@ROFI_WIDTH@" = ui.rofiWidth;
    "@ROFI_LINES@" = ui.rofiLines;
    "@SCROLLBAR_WIDTH@" = ui.scrollbarWidth;
  };

  themeText = text: builtins.replaceStrings
    (builtins.attrNames themeTokens)
    (builtins.map (name: themeTokens.${name}) (builtins.attrNames themeTokens))
    text;
in
{
  inherit palette fonts ui themeTokens themeText;
}
# hash-padding: 1
