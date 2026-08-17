local terminal = "ghostty"
local browser = "zen"

-- Fallback for outputs without a more specific rule. The generated monitors
-- module below contains the version-controlled nwg-displays layout.
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = @MONITOR_SCALE@,
})

require("monitors")
require("workspaces")

@HYPRLAND_ENV@

-- Home Manager services are attached to this target. Export Hyprland's
-- environment before starting it so every graphical service sees the session.
hl.on("hyprland.start", function()
    hl.exec_cmd([=[@DBUS_UPDATE_ACTIVATION_ENVIRONMENT@ --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE &&
@SYSTEMCTL@ --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE &&
@SYSTEMCTL@ --user start hyprland-session.target]=])

    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("@HYPRPOLKITAGENT@/libexec/hyprpolkitagent")
    hl.exec_cmd("swayosd-server")
    hl.exec_cmd("nmcli device wifi rescan >/dev/null 2>&1 || true")

    -- Start Scratchpad silently on its dedicated fifth workspace. Shelllist
    -- supplies the workspace's Scratchpad icon.
    hl.exec_cmd("@SCRATCHPAD@")
end)

hl.on("hyprland.shutdown", function()
    -- Block briefly so systemd can stop session services before Hyprland exits.
    os.execute("@SYSTEMCTL@ --user stop hyprland-session.target && sleep 0.1")
end)

hl.config({
    input = {
        kb_layout = "us,gb",
        kb_variant = "intl,",
        follow_mouse = 1,
        touchpad = {
            natural_scroll = true,
        },
    },

    general = {
        gaps_in = 1,
        gaps_out = 2,
        border_size = 1,
        col = {
            active_border = "rgba(@ACCENT_BARE@ee)",
            inactive_border = "rgba(@BORDER_DIM_BARE@aa)",
        },
        layout = "dwindle",
    },

    decoration = {
        rounding = @RADIUS_INT@,
        active_opacity = 1.0,
        inactive_opacity = 0.96,
        blur = {
            enabled = true,
            size = 2,
            passes = 1,
            vibrancy = 0.12,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
        smart_split = true,
        smart_resizing = true,
        force_split = 0,
    },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
    },

    render = {
        cm_enabled = false,
        cm_auto_hdr = 0,
    },
})

hl.curve("easeOut", {
    type = "bezier",
    points = { { 0.16, 1 }, { 0.3, 1 } },
})

for _, leaf in ipairs({ "windows", "border", "fade", "workspaces" }) do
    hl.animation({
        leaf = leaf,
        enabled = true,
        speed = 2,
        bezier = "easeOut",
    })
end

-- Window placement
hl.window_rule({
    match = { class = "^(com.mitchellh.ghostty|ghostty)$" },
    workspace = "1 silent",
})
hl.window_rule({
    match = { class = "^(zen|zen-browser|Zen|google-chrome|Google-chrome)$" },
    workspace = "2 silent",
})
hl.window_rule({
    match = { class = "^(shelllist-captive-portal)$" },
    float = true,
})
hl.window_rule({
    match = { class = [=[^(com\.gabm\.satty)$]=] },
    float = true,
    center = true,
})
hl.window_rule({
    match = { class = "^(Code|code|VSCodium|codium|jetbrains-studio)$" },
    workspace = "3 silent",
})
hl.window_rule({
    match = { class = "^(Spotify)$" },
    workspace = "4 silent",
})
hl.window_rule({
    match = { class = "^(scratchpad)$" },
    workspace = "5 silent",
})

-- Applications and session actions
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd(terminal))
hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("shelllist applications toggle"))
hl.bind("SUPER + W", hl.dsp.exec_cmd(browser))
hl.bind("SUPER + B", hl.dsp.exec_cmd("shelllist bluetooth toggle"))
hl.bind("SUPER + E", hl.dsp.exec_cmd("ghostty --class=com.laufan.yazi -e yazi"))
hl.bind("SUPER + P", hl.dsp.exec_cmd("nwg-displays-lua"))
hl.bind("SUPER + N", hl.dsp.exec_cmd("shelllist wifi toggle"))
hl.bind("SUPER + V", hl.dsp.exec_cmd("shelllist clipboard toggle"))
hl.bind("SUPER + L", hl.dsp.exec_cmd("hyprlock"))
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("SUPER + F", hl.dsp.window.float())
hl.bind("SUPER + SHIFT + F", hl.dsp.window.fullscreen())
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd("screenshot-annotate"))
hl.bind("SUPER + CTRL + S", hl.dsp.exec_cmd([=[grim -g "$(slurp)" - | wl-copy --type image/png]=]))
hl.bind("SUPER + ALT + S", hl.dsp.exec_cmd("grim - | wl-copy --type image/png"))
hl.bind("SUPER + SHIFT + Escape", hl.dsp.exec_cmd("wlogout"))
hl.bind("SUPER + K", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"))

-- Workspaces
for workspace = 1, 5 do
    hl.bind("SUPER + " .. workspace, hl.dsp.focus({ workspace = workspace }))
    hl.bind(
        "SUPER + SHIFT + " .. workspace,
        hl.dsp.window.move({ workspace = workspace, follow = true })
    )
end

hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace",
})

-- Focus, movement, and resizing
local directions = {
    LEFT = "left",
    RIGHT = "right",
    UP = "up",
    DOWN = "down",
}

for key, direction in pairs(directions) do
    hl.bind("SUPER + " .. key, hl.dsp.focus({ direction = direction }))
    hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ direction = direction }))
end

local resize_steps = {
    LEFT = { x = -30, y = 0 },
    RIGHT = { x = 30, y = 0 },
    UP = { x = 0, y = -30 },
    DOWN = { x = 0, y = 30 },
}

for key, step in pairs(resize_steps) do
    hl.bind(
        "SUPER + CTRL + " .. key,
        hl.dsp.window.resize({ x = step.x, y = step.y, relative = true })
    )
end

-- Media keys
local repeating_locked = { repeating = true, locked = true }
local locked = { locked = true }

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("swayosd-client --output-volume +5"), repeating_locked)
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("swayosd-client --output-volume -5"), repeating_locked)
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"), locked)
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("swayosd-client --input-volume mute-toggle"), locked)
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), locked)
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), locked)
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), locked)
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("swayosd-client --brightness +5"), repeating_locked)
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("swayosd-client --brightness -5"), repeating_locked)
