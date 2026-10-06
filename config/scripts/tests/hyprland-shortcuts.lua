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
hl = stub("hl")
hl.bind = function(key, action)
    assert(not bindings[key], "Duplicate shortcut: " .. key)
    bindings[key] = action
end
package.preload.monitors = function() end
package.preload.workspaces = function() end
assert(loadfile(assert(arg[1], "Expected rendered Hyprland config path")))()

local media = assert(bindings["SUPER + M"], "Super+M must open Media")
assert(media.dispatcher == "hl.dsp.global", "Media must use a global shortcut")
assert(media.arguments[1] == "shelllist:media", "Wrong Media shortcut target")
print("Hyprland shortcut registration checks passed")
