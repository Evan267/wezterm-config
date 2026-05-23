local wezterm = require 'wezterm'
local bar = wezterm.plugin.require("https://github.com/adriankarlen/bar.wezterm")
local quota = wezterm.plugin.require("https://github.com/EdenGibson/wezterm-quota-limit")
local config = wezterm.config_builder()

bar.apply_to_config(config)
quota.apply_to_config(config)

require('lua/options').apply(config)
require('lua/keys').apply(config)

return config
