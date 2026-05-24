local wezterm = require 'wezterm'
local quota = wezterm.plugin.require("https://github.com/EdenGibson/wezterm-quota-limit")
local config = wezterm.config_builder()

quota.apply_to_config(config)

local options = require('lua/options')
options.apply(config)
options.apply_dynamic_color_scheme()
require('lua/status').apply(config)
require('lua/keys').apply(config)

return config
