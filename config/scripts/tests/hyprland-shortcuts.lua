-- Evaluate the rendered config without running a compositor or its callbacks.
-- This checks binding registration, not live global-shortcut delivery.
local function stub(path)
    return setmetatable({}, {
        __index = function(_, key)
            return stub(path .. "." .. key)
        end,
        __call = function(_, ...)
            return { dispatcher = path, arguments = { ... } }
        end,
    })
end

local bindings = {}
local binding_options = {}
hl = stub("hl")
hl.bind = function(key, action, options)
    assert(not bindings[key], "Duplicate shortcut: " .. key)
    bindings[key] = action
    binding_options[key] = options
end
package.preload.monitors = function() end
package.preload.workspaces = function() end
assert(loadfile(assert(arg[1], "Expected rendered Hyprland config path")))()

local media = assert(bindings["SUPER + M"], "Super+M must open Media")
assert(media.dispatcher == "hl.dsp.global", "Media must use a global shortcut")
assert(media.arguments[1] == "shelllist:media", "Wrong Media shortcut target")
for key, target in pairs({
    ["SUPER + Home"] = "shelllist:media-back",
    ["SUPER + End"] = "shelllist:media-play-pause",
    ["SUPER + Insert"] = "shelllist:media-forward",
}) do
    local action = assert(bindings[key], key .. " must control bar media")
    assert(action.dispatcher == "hl.dsp.global", "Bar media must use a global shortcut")
    assert(action.arguments[1] == target, "Wrong bar media shortcut target")
    assert(not binding_options[key] or not binding_options[key].repeating,
        "Bar media transport must not repeat while held")
end
for key, target in pairs({
    ["SUPER + U"] = "shelllist:updates",
    ["SUPER + SHIFT + U"] = "shelllist:update-logs",
}) do
    local updates = assert(bindings[key], key .. " must open Updates")
    assert(updates.dispatcher == "hl.dsp.global", "Updates must use a global shortcut")
    assert(updates.arguments[1] == target, "Wrong Updates shortcut target")
end
for key, target in pairs({
    ["SUPER + A"] = "shelllist:agenda",
    ["SUPER + SHIFT + A"] = "shelllist:calendar",
}) do
    local action = assert(bindings[key], key .. " must open its Agenda surface")
    assert(action.dispatcher == "hl.dsp.global", "Agenda surfaces must use global shortcuts")
    assert(action.arguments[1] == target, "Wrong Agenda surface shortcut target")
end
local displays = assert(bindings["SUPER + D"], "Super+D must open Displays")
assert(displays.dispatcher == "hl.dsp.global", "Displays must use a global shortcut")
assert(displays.arguments[1] == "shelllist:displays", "Wrong Displays shortcut target")

local power = assert(bindings["SUPER + P"], "Super+P must open Battery & Power")
assert(power.dispatcher == "hl.dsp.global", "Power must use a global shortcut")
assert(power.arguments[1] == "shelllist:battery", "Wrong Power shortcut target")
local notifications = assert(bindings["SUPER + period"], "Super+. must open Notifications")
assert(notifications.dispatcher == "hl.dsp.global", "Notifications must use a global shortcut")
assert(notifications.arguments[1] == "shelllist:notifications", "Wrong Notifications shortcut target")
for workspace = 1, 10 do
    local key = tostring(workspace % 10)
    local focus = assert(bindings["SUPER + " .. key], "Missing workspace focus shortcut: " .. key)
    assert(focus.dispatcher == "hl.dsp.focus", "Workspace shortcut must focus")
    assert(focus.arguments[1].workspace == workspace, "Wrong workspace focus destination")
    local move = assert(bindings["SUPER + SHIFT + " .. key], "Missing workspace move shortcut: " .. key)
    assert(move.dispatcher == "hl.dsp.window.move", "Workspace move shortcut must move a window")
    assert(move.arguments[1].workspace == workspace, "Wrong workspace move destination")
    assert(move.arguments[1].follow == true, "Workspace move shortcut must follow the window")
end
for key, command in pairs({
    ["SUPER + CTRL + N"] = "create",
    ["SUPER + SHIFT + Q"] = "close",
    ["SUPER + CTRL + Page_Down"] = "next",
    ["SUPER + CTRL + Page_Up"] = "previous",
}) do
    local action = assert(bindings[key], "Missing workspace command: " .. key)
    assert(action.dispatcher == "hl.dsp.exec_cmd", "Workspace command must use the owner")
    assert(action.arguments[1] == "bar-daemon workspace " .. command, "Wrong workspace command")
    assert(not binding_options[key] or not binding_options[key].repeating,
        "Workspace commands must not repeat while held")
end
assert(bindings["SUPER + Q"].dispatcher == "hl.dsp.window.close", "Super+Q must close the focused window")

local middle_click = assert(bindings["mouse:274"], "Middle-click must be disabled")
assert(type(middle_click) == "function", "Middle-click must use a no-op callback")
assert(middle_click() == nil, "Middle-click must do nothing")
local middle_options = assert(binding_options["mouse:274"])
assert(middle_options.ignore_mods, "Middle-click must be disabled with modifiers")
assert(middle_options.locked, "Middle-click must be disabled while locked")
assert(middle_options.dont_inhibit, "Applications must not inhibit the middle-click block")
assert(middle_options.submap_universal, "Middle-click must be disabled in every submap")
assert(not middle_options.non_consuming, "Middle-click must not reach applications")
print("Hyprland shortcut registration checks passed")
