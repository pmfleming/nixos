{
  palette,
  scratchpad,
  clipDaemon,
}:

let
  foreground = color: { fg = color; };
  background = color: { bg = color; };
  boldForeground = color: foreground color // { bold = true; };
  colors = fg: bg: foreground fg // background bg;
  boldColors = fg: bg: colors fg bg // { bold = true; };
  underlinedColors = fg: bg: boldColors fg bg // { underline = true; };
  foregroundRule = rule: rule // foreground palette.foreground;
  boldForegroundRule = rule: rule // boldForeground palette.foreground;
in
{
  programs.yazi = {
    enable = true;
    enableBashIntegration = true;

    plugins.yank-to-clip-daemon = {
      package = clipDaemon + "/share/yazi/plugins/yank-to-clip-daemon.yazi";
      setup = true;
    };

    settings = {
      mgr = {
        ratio = [
          1
          3
          4
        ];
        show_hidden = true;
        sort_dir_first = true;
      };
      opener = {
        edit = [
          {
            run = "\${EDITOR:-nvim} \"$@\"";
            block = true;
          }
        ];
        open = [
          {
            run = ''xdg-open "$1"'';
            orphan = true;
          }
        ];
        scratchpad = [
          {
            run = ''${scratchpad}/bin/scratchpad "$@"'';
            orphan = true;
            desc = "Edit Markdown in Scratchpad";
          }
        ];
        # Satty replaced Swappy for screenshot, clipboard, and Yazi image
        # editing because Swappy does not provide post-capture cropping.
        satty = [
          {
            run = ''
              input="$1"
              case "$input" in
                *.png) output="$input" ;;
                *) output="''${input%.*}.edited.png" ;;
              esac
              exec satty \
                --filename "$input" \
                --output-filename "$output" \
                --resize smart \
                --early-exit \
                --actions-on-enter save-to-file
            '';
            orphan = true;
            desc = "Crop or annotate image in Satty";
          }
        ];
      };
      open = {
        prepend_rules = [
          {
            url = "*.md";
            use = "scratchpad";
          }
          {
            url = "*.markdown";
            use = "scratchpad";
          }
          {
            mime = "text/markdown";
            use = "scratchpad";
          }
          {
            mime = "image/*";
            use = "satty";
          }
          {
            url = "*.html";
            use = "open";
          }
          {
            url = "*.htm";
            use = "open";
          }
          {
            mime = "text/html";
            use = "open";
          }
          {
            mime = "application/xhtml+xml";
            use = "open";
          }
        ];
      };
    };

    theme = {
      mgr = {
        cwd = foreground palette.accent;
        # Yazi is a terminal TUI, so it cannot draw real rounded outline boxes
        # around rows. Keep the selected row unfilled, white, and blue-underlined
        # to avoid the default pale-blue pill.
        hovered = underlinedColors palette.foreground "reset";
        preview_hovered = underlinedColors palette.foreground "reset";
        find_keyword = boldForeground palette.accent;
        find_position = foreground palette.subtext;
        marker_copied = foreground palette.success;
        marker_cut = foreground palette.danger;
        marker_marked = foreground palette.warning;
        marker_selected = foreground palette.accent;
        tab_active = underlinedColors palette.foreground palette.bg;
        tab_inactive = colors palette.subtext palette.bg;
        border_symbol = "│";
        border_style = foreground palette.borderDim;
      };

      status = {
        separator_open = " ";
        separator_close = " ";
        separator_style = colors palette.bg palette.bg;
        mode_normal = boldColors palette.white palette.accentDark;
        mode_select = boldColors palette.white palette.accentDark;
        mode_unset = boldColors palette.white palette.dangerDark;
        progress_label = boldColors palette.white palette.accentDark;
        progress_normal = colors palette.accentDark palette.bg;
        progress_error = colors palette.dangerDark palette.bg;
        permissions_t = boldForeground palette.foreground;
        permissions_r = boldForeground palette.foreground;
        permissions_w = boldForeground palette.foreground;
        permissions_x = boldForeground palette.foreground;
        permissions_s = foreground palette.muted;
      };

      input = {
        border = foreground palette.accent;
        title = foreground palette.text;
        value = foreground palette.foreground;
        selected = background palette.selectedBg;
      };

      select = {
        border = foreground palette.accent;
        active = foreground palette.accent;
        inactive = foreground palette.subtext;
      };

      tasks = {
        border = foreground palette.accent;
        title = foreground palette.text;
        hovered = background palette.selectedBg;
      };

      which = {
        cols = 3;
        mask = background palette.bg;
        cand = foreground palette.accent;
        desc = foreground palette.subtext;
        separator = "  ";
        separator_style = foreground palette.muted;
      };

      help = {
        on = foreground palette.accent;
        run = foreground palette.subtext;
        desc = foreground palette.text;
        hovered = background palette.selectedBg;
        footer = colors palette.bg palette.text;
      };

      filetype.rules = [
        (foregroundRule { mime = "image/*"; })
        (foregroundRule { mime = "video/*"; })
        (foregroundRule { mime = "audio/*"; })
        (foregroundRule { mime = "application/zip"; })
        (foregroundRule { mime = "application/gzip"; })
        (foregroundRule { mime = "application/x-tar"; })
        (boldForegroundRule { url = "*/"; })
        (foregroundRule { url = "*"; })
      ];
    };
  };

}
