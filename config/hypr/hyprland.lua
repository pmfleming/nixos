local uwsm_app = "@UWSM_APP@"
local terminal = "ghostty"
local browser = "zen"

local function app(command)
    return uwsm_app .. " -- " .. command
end

local function session_app(command)
    return uwsm_app .. " -s s -- " .. command
end

-- Startup fallback for outputs without a more specific rule. Keep the
-- monitors module available to both existing and updated configurations.
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = @MONITOR_SCALE@,
})

require("monitors")
require("workspaces")

-- UWSM owns the graphical-session targets and loads the shared session
-- environment. Long-lived session components are declarative user services;
-- only this regular app is launched from the compositor.
hl.on("hyprland.start", function()
    -- Start Scratchpad silently on its dedicated fifth workspace. Shelllist
    -- supplies the workspace's Scratchpad icon.
    hl.exec_cmd(app("@SCRATCHPAD@"))
end)

hl.config({
    -- UWSM sends stdout to the persistent journal. Runtime-directory logs alone
    -- disappear on reboot, losing the HDMI/DPMS failure we need to diagnose.
    debug = {
        disable_logs = false,
        enable_stdout_logs = true,
    },

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

-- Consume middle-click (including touchpad-generated clicks) without affecting
-- wheel scrolling, even with modifiers, in submaps, or while locked.
hl.bind("mouse:274", function() end, {
    ignore_mods = true,
    locked = true,
    dont_inhibit = true,
    submap_universal = true,
    description = "Disable middle-click",
})

-- Applications and session actions
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd(app(terminal)))
hl.bind("SUPER + SPACE", hl.dsp.global("shelllist:applications"))
hl.bind("SUPER + A", hl.dsp.global("shelllist:agenda"))
hl.bind("SUPER + SHIFT + A", hl.dsp.global("shelllist:calendar"))
hl.bind("SUPER + T", hl.dsp.global("shelllist:time-weather"))
hl.bind("SUPER + M", hl.dsp.global("shelllist:media"))
-- Follow the bar's selected player and track/seek mode, without opening Media.
hl.bind("SUPER + Home", hl.dsp.global("shelllist:media-back"))
hl.bind("SUPER + End", hl.dsp.global("shelllist:media-play-pause"))
hl.bind("SUPER + Insert", hl.dsp.global("shelllist:media-forward"))
hl.bind("SUPER + U", hl.dsp.global("shelllist:updates"))
hl.bind("SUPER + SHIFT + U", hl.dsp.global("shelllist:update-logs"))
hl.bind("SUPER + W", hl.dsp.exec_cmd(app(browser)))
hl.bind("SUPER + B", hl.dsp.global("shelllist:bluetooth"))
hl.bind("SUPER + E", hl.dsp.exec_cmd(app("ghostty --class=com.laufan.yazi -e yazi")))
hl.bind("SUPER + D", hl.dsp.global("shelllist:displays"))
hl.bind("SUPER + P", hl.dsp.global("shelllist:battery"))
hl.bind("SUPER + N", hl.dsp.global("shelllist:wifi"))
hl.bind("SUPER + V", hl.dsp.global("shelllist:clipboard"))
hl.bind("SUPER + period", hl.dsp.global("shelllist:notifications"))
hl.bind("SUPER + L", hl.dsp.exec_cmd(session_app("hyprlock")))
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("SUPER + F", hl.dsp.window.float())
hl.bind("SUPER + SHIFT + F", hl.dsp.window.fullscreen())
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd(app("clip-daemon screenshot --annotate")))
hl.bind("SUPER + CTRL + S", hl.dsp.exec_cmd(app("clip-daemon screenshot")))
hl.bind("SUPER + ALT + S", hl.dsp.exec_cmd(app("clip-daemon screenshot --screen")))
hl.bind("SUPER + SHIFT + Escape", hl.dsp.exec_cmd(app("wlogout")))
hl.bind("SUPER + K", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"))

-- Workspaces
hl.bind("SUPER + CTRL + N", hl.dsp.exec_cmd("bar-daemon workspace create"))
hl.bind("SUPER + SHIFT + Q", hl.dsp.exec_cmd("bar-daemon workspace close"))
hl.bind("SUPER + CTRL + Page_Down", hl.dsp.exec_cmd("bar-daemon workspace next"))
hl.bind("SUPER + CTRL + Page_Up", hl.dsp.exec_cmd("bar-daemon workspace previous"))
-- The number row addresses this monitor's bar positions (0 selects the tenth).
-- The owner shares the bar's order and rejects missing positions without allocation.
-- Later positions remain reachable through the workspace strip and previous/next.
for position = 1, 10 do
    local key = tostring(position % 10)
    hl.bind("SUPER + " .. key, hl.dsp.exec_cmd("bar-daemon workspace focus " .. position .. " --position"))
    hl.bind(
        "SUPER + SHIFT + " .. key,
        hl.dsp.exec_cmd("bar-daemon workspace move " .. position .. " --position")
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

hl.bind("XF86AudioRaiseVolume", hl.dsp.global("shelllist:volume-up"), repeating_locked)
hl.bind("XF86AudioLowerVolume", hl.dsp.global("shelllist:volume-down"), repeating_locked)
hl.bind("XF86AudioMute", hl.dsp.global("shelllist:volume-mute"), locked)
hl.bind("XF86AudioMicMute", hl.dsp.global("shelllist:microphone-mute"), locked)
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), locked)
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), locked)
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), locked)
hl.bind("XF86MonBrightnessUp", hl.dsp.global("shelllist:brightness-up"), repeating_locked)
hl.bind("XF86MonBrightnessDown", hl.dsp.global("shelllist:brightness-down"), repeating_locked)
