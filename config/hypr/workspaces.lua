-- The Lua-aware nwg-displays wrapper may add monitor assignments here.
-- Keep workspaces 1-5 declared and make workspace 1 the default.
for workspace = 1, 5 do
    hl.workspace_rule({
        workspace = tostring(workspace),
        default = workspace == 1,
    })
end
