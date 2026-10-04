let
  inherit (import ./lib/scripts.nix) substitute;

  colorBare = color: builtins.substring 1 6 color;

  palette = rec {
    black = "#000000";
    bg = black;
    muted = "#69727d";
    text = "#d7dee8";
    subtext = "#aeb8c4";
    accent = "#2f8cff";

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

  fonts = rec {
    ui = "Noto Sans";
    terminal = code;
    code = "JetBrainsMono Nerd Font";
    serif = "Noto Serif";
  };

  ui = rec {
    radiusInt = 3;
    radius = "${toString radiusInt}px";
    fontSizeInt = 12;
    fontSize = toString fontSizeInt;
    scrollbarWidth = "5px";
  };

  wallpaper = ./assets/newback.png;

  appearance = {
    gtkTheme = "Adwaita-dark";
    gtkThemeEnv = "Adwaita:dark";
    gtkColorScheme = "prefer-dark";
    iconTheme = "Adwaita";
    cursorTheme = "Bibata-Modern-Ice";
    cursorSize = 24;
    qtPlatformTheme = "gtk3";
    qtStyle = "adwaita-dark";
    monitorScale = "1.25";
  };

  themeTokens = {
    "@BG@" = palette.bg;
    "@BG_BARE@" = colorBare palette.bg;
    "@MUTED@" = palette.muted;
    "@TEXT@" = palette.text;
    "@TEXT_BARE@" = colorBare palette.text;
    "@SUBTEXT@" = palette.subtext;
    "@ACCENT@" = palette.accent;
    "@ACCENT_BARE@" = colorBare palette.accent;
    "@FOREGROUND_BARE@" = colorBare palette.foreground;
    "@WHITE@" = palette.white;
    "@BORDER_DIM@" = palette.borderDim;
    "@BORDER_DIM_BARE@" = colorBare palette.borderDim;
    "@SELECTED_BG_BARE@" = colorBare palette.selectedBg;
    "@SUCCESS@" = palette.success;
    "@DANGER@" = palette.danger;
    "@DANGER_BARE@" = colorBare palette.danger;
    "@WARNING@" = palette.warning;
    "@RADIUS@" = ui.radius;
    "@RADIUS_INT@" = builtins.toString ui.radiusInt;
    "@FONT_UI@" = fonts.ui;
    "@FONT_TERMINAL@" = fonts.terminal;
    "@FONT_CODE@" = fonts.code;
    "@FONT_SIZE@" = ui.fontSize;
    "@SCROLLBAR_WIDTH@" = ui.scrollbarWidth;
    "@MONITOR_SCALE@" = appearance.monitorScale;
  };

  themeText = substitute themeTokens;
in
{
  inherit
    palette
    fonts
    ui
    appearance
    wallpaper
    themeText
    ;
}
