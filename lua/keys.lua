local w = require 'wezterm'
local M = {}

local function is_vim(pane)
  return pane:get_user_vars().IS_NVIM == 'true'
end

local direction_keys = {
  h = 'Left',
  j = 'Down',
  k = 'Up',
  l = 'Right',
}

local function split_nav(resize_or_move, key)
  return {
    key = key,
    mods = resize_or_move == 'resize' and 'META' or 'CTRL',
    action = w.action_callback(function(win, pane)
      if is_vim(pane) then
	win:perform_action({
	  SendKey = { key = key, mods = resize_or_move == 'resize' and 'META' or 'CTRL' },
	}, pane)
      else
	if resize_or_move == 'resize' then
	  win:perform_action({ AdjustPaneSize = { direction_keys[key], 3 } }, pane)
	else
	  win:perform_action({ ActivatePaneDirection = direction_keys[key] }, pane)
	end
      end
    end),
  }
end


function M.apply(config, resurrect)
  config.leader = { key = 'b', mods = 'CTRL', timeout_milliseconds = 1000 }


  local function load_resurrect_state(win, pane, close_current)
    resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id, label)
      local type = string.match(id, "^([^/]+)")
      id = string.match(id, "([^/]+)$")
      id = string.match(id, "(.+)%..+$")

      local opts = {
	relative = true,
	restore_text = true,
	on_pane_restore = resurrect.tab_state.default_on_pane_restore,
      }

      if type == "workspace" then
	local state = resurrect.state_manager.load_state(id, "workspace")
	win:perform_action(w.action.SwitchToWorkspace { name = id }, pane)
	resurrect.workspace_state.restore_workspace(state, opts)
	if close_current then
	  win:perform_action(w.action.CloseCurrentTab{ confirm = false }, pane)
	end
      elseif type == "window" then
	local state = resurrect.state_manager.load_state(id, "window")
	resurrect.window_state.restore_window(win, state, opts)

      elseif type == "tab" then
	local state = resurrect.state_manager.load_state(id, "tab")
	resurrect.tab_state.restore_tab(pane:tab(), state, opts)
      end
    end)
  end

  config.keys = {
    { key = 't', mods = 'LEADER', action = w.action.SpawnTab 'DefaultDomain' },
    { key = 'v', mods = 'LEADER', action = w.action.SplitHorizontal { domain = 'CurrentPaneDomain' } },
    { key = 's', mods = 'LEADER', action = w.action.SplitVertical { domain = 'CurrentPaneDomain' } },
    { key = 'w', mods = 'LEADER', action = w.action.CloseCurrentPane { confirm = true } },
    split_nav('move', 'h'),
    split_nav('move', 'j'),
    split_nav('move', 'k'),
    split_nav('move', 'l'),

    split_nav('resize', 'h'),
    split_nav('resize', 'j'),
    split_nav('resize', 'k'),
    split_nav('resize', 'l'),

    {
      key = "w",
      mods = "ALT",
      action = w.action_callback(function(win, pane)
	resurrect.state_manager.save_state(resurrect.workspace_state.get_workspace_state())
      end),
    },
    {
      key = "W",
      mods = "ALT",
      action = resurrect.window_state.save_window_action(),
    },
    {
      key = "T",
      mods = "ALT",
      action = resurrect.tab_state.save_tab_action(),
    },
    {
      key = "s",
      mods = "ALT",
      action = w.action_callback(function(win, pane)
	resurrect.state_manager.save_state(resurrect.workspace_state.get_workspace_state())
	resurrect.window_state.save_window_action()
      end),
    },
    {
      key = 'n',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	window:perform_action(
	  w.action.PromptInputLine {
	    description = w.format {
	      { Attribute = { Intensity = 'Bold' } },
	      { Foreground = { AnsiColor = 'Fuchsia' } },
	      { Text = 'Nommer le nouveau Workspace: ' },
	    },
	    action = w.action_callback(function(win, p, line)
	      if line and line ~= "" then
		win:perform_action(
		  w.action.SwitchToWorkspace { name = line },
		  p
		)
	      end
	    end),
	  },
	  pane
	)
      end),
    },
    {
      key = "r",
      mods = "ALT",
      action = w.action_callback(function(win, pane)
	load_resurrect_state(win, pane, false)
      end),
    },
    {
      key = "R",
      mods = "ALT",
      action = w.action_callback(function(win, pane)
	load_resurrect_state(win, pane, true)
      end),
    },
  }
end

return M
