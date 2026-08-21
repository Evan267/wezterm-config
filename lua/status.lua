local wezterm = require 'wezterm'
local domains = require 'lua/domains'
local M = {}

local palette = {
  dark = {
    fg = '#cdd6f4',
    muted = '#6c7086',
    accent = '#89b4fa',
    active_bg = '#313244',
    inactive_bg = '#181825',
    edge = '#11111b',
  },
  light = {
    fg = '#4c4f69',
    muted = '#9ca0b0',
    accent = '#1e66f5',
    active_bg = '#ccd0da',
    inactive_bg = '#e6e9ef',
    edge = '#dce0e8',
  },
}

local function is_dark_scheme(color_scheme)
  color_scheme = color_scheme or ''
  return color_scheme:find('Mocha') or color_scheme:find('Dark')
end

local function colors_for_scheme(color_scheme)
  return is_dark_scheme(color_scheme) and palette.dark or palette.light
end

local function basename(path)
  if not path or path == '' then
    return ''
  end

  local normalized = path:gsub('\\', '/')
  return normalized:match('([^/]+)/?$') or normalized
end

-- `pane` est un PaneInformation (passe par format-tab-title) : champs, pas methodes.
local function pane_title(pane)
  local title = pane.title

  if title and title ~= '' then
    return title
  end

  return basename(pane.foreground_process_name) or 'shell'
end

local function tab_title(tab)
  if tab.tab_title and tab.tab_title ~= '' then
    return tab.tab_title
  end

  return pane_title(tab.active_pane)
end

local function active_workspace(window)
  local ok, name = pcall(function()
    return window:active_workspace()
  end)

  if ok and name and name ~= '' then
    return name
  end

  return 'default'
end

-- Scheme de la FENETRE, sans reconstruire toute la config. `effective_config()`
-- reconstruit la table complete a chaque appel : le payer une fois par seconde
-- et par fenetre pour en lire UN champ etait le plus cher des trois travers
-- releves le 2026-08-21 (cf. lua/notify.lua). Le scheme est deja pose en
-- override par fenetre par lua/options.lua, avec le dernier connu dans GLOBAL.
local function window_color_scheme(window)
  local ok, overrides = pcall(function()
    return window:get_config_overrides()
  end)

  if ok and type(overrides) == 'table' and overrides.color_scheme then
    return overrides.color_scheme
  end

  return wezterm.GLOBAL.dynamic_color_scheme
end

-- Dernier statut REELLEMENT pose, par fenetre : `set_left_status` salit la barre
-- meme quand le texte ne change pas, donc le reposer a chaque tick fait
-- repeindre la fenetre pour rien.
local last_status = {}

function M.apply(config)
  config.use_fancy_tab_bar = false
  config.hide_tab_bar_if_only_one_tab = false
  config.tab_bar_at_bottom = false
  config.show_new_tab_button_in_tab_bar = false

  wezterm.on('update-status', function(window, pane)
    local scheme = window_color_scheme(window)
    local c = colors_for_scheme(scheme)
    local workspace = active_workspace(window)
    -- Domaine REEL du pane actif (et non le defaut de la fenetre) : c'est la
    -- seule indication fiable de la machine ou tourne ce qu'on a sous les yeux,
    -- workspaces locaux et distants pouvant cohabiter. Repli sur le defaut de la
    -- fenetre quand le pane n'en expose pas (overlay, pane mort).
    local domain = domains.pane_domain(pane) or domains.window_default(window)
    local domain_fg = domains.is_remote(domain) and c.accent or c.muted

    local ok_id, window_id = pcall(function()
      return window:window_id()
    end)

    -- Le statut ne depend que de ces trois valeurs : tant qu'elles ne bougent
    -- pas, il n'y a rien a reposer.
    local key = tostring(scheme) .. '\0' .. tostring(workspace)
      .. '\0' .. tostring(domains.label(domain))
    local memo = (ok_id and window_id) or 'sans-id'

    if last_status[memo] == key then
      return
    end

    last_status[memo] = key

    window:set_left_status(wezterm.format {
      { Background = { Color = c.edge } },
      { Foreground = { Color = c.accent } },
      { Attribute = { Intensity = 'Bold' } },
      { Text = ' WS ' },
      { Foreground = { Color = c.fg } },
      { Attribute = { Intensity = 'Normal' } },
      { Text = workspace .. ' ' },
      { Foreground = { Color = domain_fg } },
      { Text = '[' .. domains.label(domain) .. '] ' },
    })
  end)

  wezterm.on('format-tab-title', function(tab, _, _, config_, _, max_width)
    local c = colors_for_scheme(config_.color_scheme)
    local bg = tab.is_active and c.active_bg or c.inactive_bg
    local fg = tab.is_active and c.fg or c.muted
    local edge_fg = tab.is_active and c.accent or c.edge
    local title = tab_title(tab)
    local index = tostring(tab.tab_index + 1)
    local text = ' ' .. index .. ' ' .. title .. ' '

    if max_width and #text > max_width then
      text = wezterm.truncate_right(text, max_width - 1) .. ' '
    end

    return {
      { Background = { Color = c.edge } },
      { Foreground = { Color = edge_fg } },
      { Text = tab.is_active and '▌' or ' ' },
      { Background = { Color = bg } },
      { Foreground = { Color = fg } },
      { Text = text },
      { Background = { Color = c.edge } },
      { Foreground = { Color = bg } },
      { Text = ' ' },
    }
  end)
end

return M
