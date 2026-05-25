local wezterm = require 'wezterm'
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

local function pane_title(pane)
  local title = pane:get_title()

  if title and title ~= '' then
    return title
  end

  return basename(pane:get_foreground_process_name()) or 'shell'
end

local function tab_title(tab)
  if tab.tab_title and tab.tab_title ~= '' then
    return tab.tab_title
  end

  return pane_title(tab.active_pane)
end

function M.apply(config)
  config.use_fancy_tab_bar = false
  config.hide_tab_bar_if_only_one_tab = false
  config.tab_bar_at_bottom = false
  config.show_new_tab_button_in_tab_bar = false

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
