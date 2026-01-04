local wezterm = require 'wezterm'
local M = {}

function M.apply(config)
    config.color_scheme = 'Catppuccin Mocha'
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
