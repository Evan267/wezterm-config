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

wezterm.on("gui-startup", resurrect.state_manager.resurrect_on_gui_startup)
-- loads the state whenever I create a new workspace
wezterm.on("smart_workspace_switcher.workspace_switcher.created", function(window, path, label)
  local workspace_state = resurrect.workspace_state

  workspace_state.restore_workspace(resurrect.state_manager.load_state(label, "workspace"), {
    window = window,
    relative = true,
    restore_text = true,
    on_pane_restore = resurrect.tab_state.default_on_pane_restore,
  })
end)

-- Saves the state whenever I select a workspace
wezterm.on("smart_workspace_switcher.workspace_switcher.selected", function(window, path, label)
  local workspace_state = resurrect.workspace_state
  resurrect.state_manager.save_state(workspace_state.get_workspace_state())
end)

return config
