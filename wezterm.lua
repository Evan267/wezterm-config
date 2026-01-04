local wezterm = require 'wezterm'

local resurrect = wezterm.plugin.require("https://github.com/MLFlexer/resurrect.wezterm")

local bar = wezterm.plugin.require("https://github.com/adriankarlen/bar.wezterm")

resurrect.save_state = resurrect.state_manager.save_state
resurrect.load_state = resurrect.state_manager.load_state

package.loaded["resurrect"] = resurrect
local config = wezterm.config_builder()

bar.apply_to_config(config)

require('lua/options').apply(config)
require('lua/keys').apply(config, resurrect)

return config
