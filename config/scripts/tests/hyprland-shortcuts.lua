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
    ["SUPER + U"] = "shelllist:updates",
    ["SUPER + SHIFT + U"] = "shelllist:update-logs",
}) do
    local updates = assert(bindings[key], key .. " must open Updates")
    assert(updates.dispatcher == "hl.dsp.global", "Updates must use a global shortcut")
    assert(updates.arguments[1] == target, "Wrong Updates shortcut target")
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
