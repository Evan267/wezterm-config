local wezterm = require 'wezterm'
local config = wezterm.config_builder()

local options = require('lua/options')
options.apply(config)
options.apply_dynamic_color_scheme()
options.apply_startup_maximize()
require('lua/domains').apply(config)
require('lua/status').apply(config)
require('lua/keys').apply(config)
require('lua/workspaces').start_auto_save()

return config
