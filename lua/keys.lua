local w = require 'wezterm'
local workspaces = require 'lua/workspaces'
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


function M.apply(config)
  config.leader = { key = 'b', mods = 'CTRL', timeout_milliseconds = 1000 }

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
      key = 'n',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.prompt_new_workspace(window, pane)
      end),
    },
    {
      key = 'r',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.save_current(window, pane)
      end),
    },
    {
      key = 'o',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.choose_registered(window, pane, 'current')
      end),
    },
    {
      key = 'O',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.choose_registered(window, pane, 'new')
      end),
    },
    {
      key = 'd',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.choose_delete_registered(window, pane)
      end),
    },
    {
      key = 'LeftArrow',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.activate_relative(window, pane, -1)
      end),
    },
    {
      key = 'RightArrow',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.activate_relative(window, pane, 1)
      end),
    },
  }
end

return M
