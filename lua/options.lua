local wezterm = require 'wezterm'
local M = {}

local function color_scheme_for_appearance(appearance)
    if appearance:find('Dark') then
        return 'Catppuccin Mocha'
    end

    return 'Catppuccin Latte'
end

function M.apply(config)
    local appearance = wezterm.gui and wezterm.gui.get_appearance() or 'Dark'
    config.color_scheme = color_scheme_for_appearance(appearance)
    config.font = wezterm.font('JetBrains Mono')
    
    config.window_decorations = "RESIZE"
    config.window_background_opacity = 0.95
    
    config.window_padding = { left = 5, right = 5, top = 5, bottom = 5 }
    
    config.inactive_pane_hsb = {
        saturation = 0.9,
        brightness = 0.5,
    }
end

return M
