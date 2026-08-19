local w = require 'wezterm'
local workspaces = require 'lua/workspaces'
local domains = require 'lua/domains'
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

-- Deblocage du suivi souris/focus reste actif apres la mort d'une appli TUI.
--
-- Sur un pane MUX (nos panes tournent sur le wezterm-mux-server de vibe), l'etat
-- du terminal (modes DEC, suivi souris) vit COTE SERVEUR : pane:inject_output ne
-- marche que sur les panes locaux, pas mux (cf. doc WezTerm). Le seul moyen fiable
-- et portable (local comme mux) est de faire ECRIRE les sequences de reset par le
-- shell : sa sortie repasse dans le parseur du terminal (cote serveur pour un mux)
-- et remet les modes a zero. On envoie donc un printf via send_text.
--
-- \x15 (Ctrl-U) purge d'abord la ligne des octets parasites deja tapes ; les
-- '\\033' sont des backslashs LITTERAUX destines au printf de bash (ESC), pas des
-- echappements Lua ; \r valide la commande.
local RESET_MOUSE_CMD = '\x15' .. "printf '" .. table.concat({
  '\\033[?9l',    -- X10 mouse
  '\\033[?1000l', -- suivi normal (clic)
  '\\033[?1001l', -- surbrillance
  '\\033[?1002l', -- button-event (drag)
  '\\033[?1003l', -- any-event : le coupable du "souris = frappe clavier"
  '\\033[?1004l', -- focus reporting (sequences [I / [O parasites)
  '\\033[?1005l', -- extension UTF-8
  '\\033[?1006l', -- extension SGR
  '\\033[?1015l', -- extension urxvt
  '\\033[?1016l', -- extension SGR pixel
}) .. "'\r"

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
    {
      key = 't',
      mods = 'LEADER',
      action = w.action_callback(function(window, pane)
	workspaces.spawn_tab(window, pane)
      end),
    },
    {
      key = 'v',
      mods = 'LEADER',
      action = w.action_callback(function(window, pane)
	workspaces.split_pane(window, pane, 'Right')
      end),
    },
    {
      key = 's',
      mods = 'LEADER',
      action = w.action_callback(function(window, pane)
	workspaces.split_pane(window, pane, 'Bottom')
      end),
    },
    { key = 'w', mods = 'LEADER', action = w.action.CloseCurrentPane { confirm = true } },
    {
      -- Deblocage du suivi souris reste actif apres la mort d'une appli TUI.
      -- Fait ecrire les DECRST par le shell (cf. RESET_MOUSE_CMD) : fiable sur les
      -- panes mux ou pane:inject_output n'a aucun effet. A utiliser au prompt shell.
      key = 'm',
      mods = 'LEADER',
      action = w.action.SendString(RESET_MOUSE_CMD),
    },
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
      key = 't',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.prompt_rename_active_tab(window, pane)
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
	workspaces.choose_registered(window, pane)
      end),
    },
    {
      key = 'R',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.restore_all_active(window, pane)
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
      key = 'a',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.choose_archive(window, pane)
      end),
    },
    {
      key = 'u',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	workspaces.choose_unarchive(window, pane)
      end),
    },
    {
      -- Bascule locale/distante du domaine par defaut de la fenetre courante.
      -- N'affecte que les spawns sans contexte : les workspaces enregistres
      -- gardent le domaine fige dans workspaces.json.
      key = 'D',
      mods = 'ALT',
      action = w.action_callback(function(window, pane)
	domains.prompt_switch_default(window, pane)
      end),
    },
    {
      key = 'Q',
      mods = 'ALT',
      action = w.action.QuitApplication,
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
