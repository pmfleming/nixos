{ palette }:

{
  programs.yazi = {
    enable = true;
    enableBashIntegration = true;

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
        cwd = {
          fg = palette.accent;
        };
        # Yazi is a terminal TUI, so it cannot draw real rounded outline boxes
        # around rows. Keep the selected row unfilled, white, and blue-underlined
        # to avoid the default pale-blue pill.
        hovered = {
          fg = palette.foreground;
          bg = "reset";
          bold = true;
          underline = true;
        };
        preview_hovered = {
          fg = palette.foreground;
          bg = "reset";
          bold = true;
          underline = true;
        };
        find_keyword = {
          fg = palette.accent;
          bold = true;
        };
        find_position = {
          fg = palette.subtext;
        };
        marker_copied = {
          fg = palette.success;
        };
        marker_cut = {
          fg = palette.danger;
        };
        marker_marked = {
          fg = palette.warning;
        };
        marker_selected = {
          fg = palette.accent;
        };
        tab_active = {
          fg = palette.foreground;
          bg = palette.bg;
          bold = true;
          underline = true;
        };
        tab_inactive = {
          fg = palette.subtext;
          bg = palette.bg;
        };
        border_symbol = "│";
        border_style = {
          fg = palette.borderDim;
        };
      };

      status = {
        separator_open = " ";
        separator_close = " ";
        separator_style = {
          fg = palette.bg;
          bg = palette.bg;
        };
        mode_normal = {
          fg = palette.white;
          bg = palette.accentDark;
          bold = true;
        };
        mode_select = {
          fg = palette.white;
          bg = palette.accentDark;
          bold = true;
        };
        mode_unset = {
          fg = palette.white;
          bg = palette.dangerDark;
          bold = true;
        };
        progress_label = {
          fg = palette.white;
          bg = palette.accentDark;
          bold = true;
        };
        progress_normal = {
          fg = palette.accentDark;
          bg = palette.bg;
        };
        progress_error = {
          fg = palette.dangerDark;
          bg = palette.bg;
        };
        permissions_t = {
          fg = palette.foreground;
          bold = true;
        };
        permissions_r = {
          fg = palette.foreground;
          bold = true;
        };
        permissions_w = {
          fg = palette.foreground;
          bold = true;
        };
        permissions_x = {
          fg = palette.foreground;
          bold = true;
        };
        permissions_s = {
          fg = palette.muted;
        };
      };

      input = {
        border = {
          fg = palette.accent;
        };
        title = {
          fg = palette.text;
        };
        value = {
          fg = palette.foreground;
        };
        selected = {
          bg = palette.selectedBg;
        };
      };

      select = {
        border = {
          fg = palette.accent;
        };
        active = {
          fg = palette.accent;
        };
        inactive = {
          fg = palette.subtext;
        };
      };

      tasks = {
        border = {
          fg = palette.accent;
        };
        title = {
          fg = palette.text;
        };
        hovered = {
          bg = palette.selectedBg;
        };
      };

      which = {
        cols = 3;
        mask = {
          bg = palette.bg;
        };
        cand = {
          fg = palette.accent;
        };
        desc = {
          fg = palette.subtext;
        };
        separator = "  ";
        separator_style = {
          fg = palette.muted;
        };
      };

      help = {
        on = {
          fg = palette.accent;
        };
        run = {
          fg = palette.subtext;
        };
        desc = {
          fg = palette.text;
        };
        hovered = {
          bg = palette.selectedBg;
        };
        footer = {
          fg = palette.bg;
          bg = palette.text;
        };
      };

      filetype = {
        rules = [
          {
            mime = "image/*";
            fg = palette.foreground;
          }
          {
            mime = "video/*";
            fg = palette.foreground;
          }
          {
            mime = "audio/*";
            fg = palette.foreground;
          }
          {
            mime = "application/zip";
            fg = palette.foreground;
          }
          {
            mime = "application/gzip";
            fg = palette.foreground;
          }
          {
            mime = "application/x-tar";
            fg = palette.foreground;
          }
          {
            url = "*/";
            fg = palette.foreground;
            bold = true;
          }
          {
            url = "*";
            fg = palette.foreground;
          }
        ];
      };
    };
  };

}
