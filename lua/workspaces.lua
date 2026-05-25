local wezterm = require 'wezterm'
local M = {}

local registry_path = wezterm.config_dir .. '/workspaces.json'
local debug_path = wezterm.config_dir .. '/workspaces-debug.log'
local snapshot_version = 1
local default_wsl_distro = 'Debian'
local notification_duration = 2500
local error_notification_duration = 5000
local notification_serial = 0

local shell_names = {
  bash = true,
  cmd = true,
  ['cmd.exe'] = true,
  fish = true,
  nu = true,
  ['nu.exe'] = true,
  powershell = true,
  ['powershell.exe'] = true,
  pwsh = true,
  ['pwsh.exe'] = true,
  sh = true,
  zsh = true,
}

local function read_file(path)
  local file = io.open(path, 'r')

  if not file then
    return nil
  end

  local content = file:read('*a')
  file:close()
  return content
end

local function write_file(path, content)
  local file, err = io.open(path, 'w')

  if not file then
    wezterm.log_error("Impossible d'ecrire les workspaces: " .. tostring(err))
    return false
  end

  file:write(content)
  file:close()
  return true
end

local function append_debug(message)
  local file = io.open(debug_path, 'a')

  if not file then
    return
  end

  file:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. tostring(message) .. '\n')
  file:close()
end

local function notify(window, message, duration)
  duration = duration or notification_duration
  notification_serial = notification_serial + 1
  local serial = notification_serial

  pcall(function()
    window:toast_notification('WezTerm', message, nil, duration)
  end)

  window:set_right_status(wezterm.format {
    { Attribute = { Intensity = 'Bold' } },
    { Foreground = { AnsiColor = 'Aqua' } },
    { Text = ' ' .. message .. ' ' },
  })

  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(duration / 1000, function()
      if serial == notification_serial then
        pcall(function()
          window:set_right_status('')
        end)
      end
    end)
  end
end

local function notify_error(window, message)
  notify(window, message, error_notification_duration)
end

local function normalize_registry(value)
  if type(value) ~= 'table' then
    return { workspaces = {} }
  end

  if type(value.workspaces) ~= 'table' then
    value.workspaces = {}
  end

  return value
end

local function load_registry()
  local content = read_file(registry_path)

  if not content or content == '' then
    return { workspaces = {} }
  end

  local ok, decoded = pcall(wezterm.json_parse, content)

  if not ok then
    wezterm.log_error('Impossible de lire ' .. registry_path .. ': ' .. tostring(decoded))
    return { workspaces = {} }
  end

  return normalize_registry(decoded)
end

local function save_registry(registry)
  return write_file(registry_path, wezterm.json_encode(normalize_registry(registry)))
end

local function basename(path)
  if not path or path == '' then
    return nil
  end

  return path:gsub('\\', '/'):match('([^/]+)$') or path
end

local function is_shell(argv)
  if type(argv) ~= 'table' or type(argv[1]) ~= 'string' then
    return false
  end

  return shell_names[basename(argv[1])] == true
end

local function copy_array(value)
  if type(value) ~= 'table' then
    return nil
  end

  local result = {}

  for _, item in ipairs(value) do
    if type(item) == 'string' and item ~= '' then
      table.insert(result, item)
    end
  end

  if #result == 0 then
    return nil
  end

  return result
end

local function workspace_name(window)
  local ok, name = pcall(function()
    return window:active_workspace()
  end)

  if ok and name and name ~= '' then
    return name
  end

  return 'default'
end

local function canonical_workspace_name(name)
  if type(name) ~= 'string' then
    return 'default'
  end

  return name:match('^(.-) live %d%d%d%d%d%d$') or name
end

local function live_workspace_name(name)
  return canonical_workspace_name(name) .. ' live ' .. os.date('%H%M%S')
end

local function is_windows()
  return wezterm.target_triple:find('windows') ~= nil
end

local function wsl_distro()
  return wezterm.GLOBAL.wsl_distro or default_wsl_distro
end

local function windows_path_to_wsl(path)
  if type(path) ~= 'string' then
    return path
  end

  if not is_windows() then
    return path
  end

  local drive, rest = path:match('^/([A-Za-z]):[/\\]?(.*)$')

  if not drive then
    drive, rest = path:match('^([A-Za-z]):[/\\]?(.*)$')
  end

  if not drive then
    return path
  end

  rest = (rest or ''):gsub('\\', '/')
  return '/mnt/' .. drive:lower() .. (rest ~= '' and '/' .. rest or '')
end

local function bash_quote(value)
  return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

local function shell_init_file()
  return windows_path_to_wsl(wezterm.config_dir .. '/shell/bash-workspace-tracker.bash')
end

local function shell_command_args(command)
  return {
    'bash',
    '--init-file',
    shell_init_file(),
    '-i',
    '-c',
    command .. '\nexec bash --init-file ' .. bash_quote(shell_init_file()) .. ' -i',
  }
end

local function tmux_session_name(name)
  name = canonical_workspace_name(name or 'default')
  name = name:gsub('[^%w_.%-]', '_')

  if name == '' then
    return 'default'
  end

  return name
end

local function tmux_slot_name(slot)
  slot = tostring(slot or 'main'):gsub('[^%w_.%-]', '_')

  if slot == '' then
    return 'main'
  end

  return slot
end

local function tmux_workspace_spawn(name, slot)
  local group = tmux_session_name(name)
  local base = group .. '__wezterm_' .. tmux_slot_name(slot)
  local script = table.concat({
    'group=' .. bash_quote(group),
    'base=' .. bash_quote(base),
    'client="$base"',
    'tmux has-session -t "$group" 2>/dev/null || tmux new-session -d -s "$group"',
    'if tmux has-session -t "$client" 2>/dev/null && tmux list-clients -t "$client" >/dev/null 2>&1; then i=1; while tmux has-session -t "${base}_${i}" 2>/dev/null && tmux list-clients -t "${base}_${i}" >/dev/null 2>&1; do i=$((i + 1)); done; client="${base}_${i}"; fi',
    'tmux has-session -t "$client" 2>/dev/null || tmux new-session -d -t "$group" -s "$client"',
    'exec tmux attach-session -t "$client"',
  }, '; ')

  return {
    args = { 'sh', '-lc', script },
  }
end

local function path_exists(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end

  local ok, success = pcall(function()
    return wezterm.run_child_process({ 'test', '-d', path })
  end)

  if ok and success == true then
    return true
  end

  return false
end

local function current_working_dir(pane)
  local cwd = pane:get_current_working_dir()

  if type(cwd) == 'userdata' and (not cwd.scheme or cwd.scheme == 'file') and cwd.file_path then
    return windows_path_to_wsl(cwd.file_path)
  end

  if type(cwd) == 'string' then
    local ok, parsed = false, nil

    if wezterm.url and wezterm.url.parse then
      ok, parsed = pcall(wezterm.url.parse, cwd)
    end

    if ok and parsed and (not parsed.scheme or parsed.scheme == 'file') and parsed.file_path then
      return windows_path_to_wsl(parsed.file_path)
    end

    return windows_path_to_wsl(cwd:gsub('^file://', ''))
  end

  return nil
end

local function pane_process_argv(pane)
  local ok, process = pcall(function()
    return pane:get_foreground_process_info()
  end)

  if not ok or type(process) ~= 'table' then
    return nil
  end

  local argv = copy_array(process.argv)

  if argv then
    return argv
  end

  if type(process.executable) == 'string' and process.executable ~= '' then
    return { process.executable }
  end

  return nil
end

local function pane_title(pane)
  local ok, title = pcall(function()
    return pane:get_title()
  end)

  if ok and type(title) == 'string' and title ~= '' then
    return title
  end

  return nil
end

local function pane_user_vars(pane)
  local ok, vars = pcall(function()
    return pane:get_user_vars()
  end)

  if ok and type(vars) == 'table' then
    return vars
  end

  return {}
end

local function pane_user_var(pane, name)
  local value = pane_user_vars(pane)[name]

  if type(value) == 'string' and value ~= '' then
    return value
  end

  return nil
end

local function tab_title(tab)
  local ok, title = pcall(function()
    return tab:get_title()
  end)

  if ok and type(title) == 'string' and title ~= '' then
    return title
  end

  return nil
end

local function set_tab_title(tab, title)
  if type(title) ~= 'string' or title == '' then
    return
  end

  pcall(function()
    tab:set_title(title)
  end)
end

local function active_tab(window)
  local ok, tab = pcall(function()
    return window:active_tab()
  end)

  if ok and tab then
    return tab
  end

  ok, tab = pcall(function()
    return window:mux_window():active_tab()
  end)

  if ok and tab then
    return tab
  end

  local mux_window = window:mux_window()

  for _, item in ipairs(mux_window:tabs_with_info()) do
    if item.is_active then
      return item.tab
    end
  end

  return nil
end

local function cwd_from_title(title)
  if type(title) ~= 'string' then
    return nil
  end

  local cwd = title:match('^[^:]+:%s+(.+)$')

  if not cwd or cwd == '' then
    return nil
  end

  cwd = cwd:gsub('%s+$', '')

  if cwd:match('^~/') or cwd:match('^/') or cwd:match('^[A-Za-z]:[/\\]') then
    return windows_path_to_wsl(cwd)
  end

  return nil
end

local function find_workspace(registry, name)
  for index, workspace in ipairs(registry.workspaces) do
    if workspace.name == name then
      return workspace, index
    end
  end

  return nil, nil
end

local function registered_workspaces(registry)
  local result = {}

  for _, workspace in ipairs(registry.workspaces) do
    if workspace.name == canonical_workspace_name(workspace.name) then
      table.insert(result, workspace)
    end
  end

  return result
end

local function remove_workspace(name)
  local registry = load_registry()
  local _, remove_index = find_workspace(registry, name)

  if not remove_index then
    return false
  end

  table.remove(registry.workspaces, remove_index)
  return save_registry(registry)
end

local function upsert_workspace(name, snapshot)
  append_debug('upsert start name=' .. tostring(name))
  local registry = load_registry()
  local existing = find_workspace(registry, name)
  snapshot.name = name

  if existing then
    for key in pairs(existing) do
      existing[key] = nil
    end

    for key, value in pairs(snapshot) do
      existing[key] = value
    end
  else
    table.insert(registry.workspaces, snapshot)
  end

  local saved = save_registry(registry)
  append_debug('upsert saved=' .. tostring(saved) .. ' name=' .. tostring(name))
  return saved
end

local function pane_spawn(pane_snapshot)
  if type(pane_snapshot) ~= 'table' then
    return nil
  end

  local cwd = windows_path_to_wsl(pane_snapshot.cwd)
  local argv = copy_array(pane_snapshot.argv)
  local command = type(pane_snapshot.last_command) == 'string' and pane_snapshot.last_command or nil
  local spawn = {}

  if argv and (argv[1]:match('^%-%-') or pane_snapshot.title == 'wslhost.exe') then
    argv = nil
  end

  if command == '' or (command and command:find('[\r\n]')) then
    command = nil
  end

  if cwd and cwd ~= '' then
    if not is_windows() and cwd:match('^/mnt/[A-Za-z]/') and not path_exists(cwd) then
      cwd = nil
    end
  end

  if cwd and cwd ~= '' then
    if is_windows() and cwd:match('^/') and not cwd:match('^//') then
      local args = { 'wsl.exe', '-d', wsl_distro(), '--cd', cwd }

      if command then
        table.insert(args, '--')
        for _, arg in ipairs(shell_command_args(command)) do
          table.insert(args, arg)
        end
      elseif argv and not is_shell(argv) then
        table.insert(args, '--')

        for _, arg in ipairs(argv) do
          table.insert(args, arg)
        end
      end

      spawn.args = args
      return spawn
    end

    spawn.cwd = cwd
  end

  if command then
    spawn.args = shell_command_args(command)
  elseif argv and not is_shell(argv) then
    spawn.args = argv
  end

  if spawn.cwd or spawn.args then
    return spawn
  end

  return nil
end

local function first_pane(tab_snapshot)
  if type(tab_snapshot) ~= 'table' or type(tab_snapshot.panes) ~= 'table' then
    return {}
  end

  return tab_snapshot.panes[1] or {}
end

local function first_leaf_pane(node)
  if type(node) ~= 'table' then
    return {}
  end

  if node.kind == 'pane' then
    return node.pane or {}
  end

  if node.kind == 'split' then
    return first_leaf_pane(node.first)
  end

  if node.kind == 'stack' and type(node.panes) == 'table' then
    return node.panes[1] or {}
  end

  return {}
end

local function merge_spawn_options(base, spawn)
  if spawn then
    for key, value in pairs(spawn) do
      base[key] = value
    end
  end

  return base
end

local function workspace_tmux_pane_spawn(workspace, tab_index, pane_index)
  return tmux_workspace_spawn(workspace.name, 'tab' .. tostring(tab_index) .. '_pane' .. tostring(pane_index))
end

local function focus_mux_window(mux_window)
  if not mux_window then
    return
  end

  pcall(function()
    local gui_window = mux_window:gui_window()
    gui_window:restore()
    gui_window:focus()
  end)
end

local function focus_mux_window_soon(mux_window)
  focus_mux_window(mux_window)

  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(0.2, function()
      focus_mux_window(mux_window)
    end)
    wezterm.time.call_after(0.6, function()
      focus_mux_window(mux_window)
    end)
  end
end

local function workspace_exists(name)
  if wezterm.mux and wezterm.mux.get_workspace_names then
    for _, workspace in ipairs(wezterm.mux.get_workspace_names()) do
      if workspace == name then
        return true
      end
    end
  end

  if not wezterm.mux or not wezterm.mux.all_windows then
    return false
  end

  for _, mux_window in ipairs(wezterm.mux.all_windows()) do
    local ok, workspace = pcall(function()
      return mux_window:get_workspace()
    end)

    if ok and workspace == name then
      return true
    end
  end

  return false
end

local function focus_workspace_window(name)
  if not wezterm.mux or not wezterm.mux.all_windows then
    return false
  end

  for _, mux_window in ipairs(wezterm.mux.all_windows()) do
    local ok, workspace = pcall(function()
      return mux_window:get_workspace()
    end)

    if ok and workspace == name then
      local focus_ok = pcall(function()
        mux_window:gui_window():focus()
      end)

      if focus_ok then
        return true
      end
    end
  end

  return false
end

local function pane_rect(pane_info)
  return {
    cols = pane_info.width or 1,
    rows = pane_info.height or 1,
    x = pane_info.left or 0,
    y = pane_info.top or 0,
  }
end

local function sorted_panes(panes)
  table.sort(panes, function(left, right)
    if left.y == right.y then
      return left.x < right.x
    end

    return left.y < right.y
  end)

  return panes
end

local function mux_window_tabs(mux_window)
  local ok, tabs = pcall(function()
    return mux_window:tabs()
  end)

  if ok and type(tabs) == 'table' then
    append_debug('mux_window:tabs ok count=' .. tostring(#tabs))
    return tabs
  end

  append_debug('mux_window:tabs failed: ' .. tostring(tabs))

  ok, tabs = pcall(function()
    return mux_window:tabs_with_info()
  end)

  if ok and type(tabs) == 'table' then
    local result = {}

    for _, item in ipairs(tabs) do
      table.insert(result, item.tab or item)
    end

    append_debug('mux_window:tabs_with_info ok count=' .. tostring(#result))
    return result
  end

  append_debug('mux_window:tabs_with_info failed: ' .. tostring(tabs))
  return {}
end

local function capture_current_window(window, active_pane)
  append_debug('capture start')
  local mux_window = window:mux_window()
  local tabs = {}

  for _, tab in ipairs(mux_window_tabs(mux_window)) do
    local panes = {}
    local ok, panes_with_info = pcall(function()
      return tab:panes_with_info()
    end)

    if not ok or type(panes_with_info) ~= 'table' then
      append_debug('tab:panes_with_info failed: ' .. tostring(panes_with_info))
      panes_with_info = {}
    end

    for _, item in ipairs(panes_with_info) do
      local p = item.pane
      local rect = pane_rect(item)
      local argv = pane_process_argv(p)
      local command = argv and table.concat(argv, ' ') or nil
      local title = pane_title(p)
      local tracked_cwd = pane_user_var(p, 'WEZTERM_WORKSPACE_CWD')
      local last_command = pane_user_var(p, 'WEZTERM_WORKSPACE_LAST_COMMAND')
      local cwd = tracked_cwd or cwd_from_title(title) or current_working_dir(p)

      if argv and (argv[1]:match('^%-%-') or title == 'wslhost.exe') then
        argv = nil
        command = nil
      end

      table.insert(panes, {
        cwd = cwd,
        argv = argv,
        command = command,
        last_command = last_command,
        title = title,
        x = rect.x,
        y = rect.y,
        cols = rect.cols,
        rows = rect.rows,
        is_active = item.is_active == true,
      })
    end

    table.insert(tabs, {
      title = tab_title(tab),
      panes = sorted_panes(panes),
    })

    append_debug('captured tab panes=' .. tostring(#panes))
  end

  local snapshot = {
    version = snapshot_version,
    cwd = active_pane and (pane_user_var(active_pane, 'WEZTERM_WORKSPACE_CWD') or current_working_dir(active_pane))
      or first_pane(tabs[1]).cwd,
    tabs = tabs,
    saved_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }

  append_debug('capture done tabs=' .. tostring(#tabs))
  return snapshot
end

local function bounds(panes)
  local min_x, min_y, max_x, max_y = math.huge, math.huge, 0, 0

  for _, pane in ipairs(panes) do
    min_x = math.min(min_x, pane.x or 0)
    min_y = math.min(min_y, pane.y or 0)
    max_x = math.max(max_x, (pane.x or 0) + (pane.cols or 1))
    max_y = math.max(max_y, (pane.y or 0) + (pane.rows or 1))
  end

  return { x = min_x, y = min_y, cols = math.max(1, max_x - min_x), rows = math.max(1, max_y - min_y) }
end

local function split_groups(panes, axis)
  local start_key = axis == 'x' and 'x' or 'y'
  local size_key = axis == 'x' and 'cols' or 'rows'
  local cuts = {}

  for _, pane in ipairs(panes) do
    table.insert(cuts, (pane[start_key] or 0) + (pane[size_key] or 1))
  end

  table.sort(cuts)

  for _, cut in ipairs(cuts) do
    local before, after, crosses = {}, {}, false

    for _, pane in ipairs(panes) do
      local start = pane[start_key] or 0
      local finish = start + (pane[size_key] or 1)

      if finish <= cut then
        table.insert(before, pane)
      elseif start >= cut then
        table.insert(after, pane)
      else
        crosses = true
        break
      end
    end

    if not crosses and #before > 0 and #after > 0 then
      return sorted_panes(before), sorted_panes(after)
    end
  end

  return nil, nil
end

local function build_layout(panes)
  if #panes == 0 then
    return nil
  end

  if #panes == 1 then
    return { kind = 'pane', pane = panes[1] }
  end

  local left, right = split_groups(panes, 'x')

  if left and right then
    return {
      kind = 'split',
      direction = 'Right',
      first = build_layout(left),
      second = build_layout(right),
      first_bounds = bounds(left),
      second_bounds = bounds(right),
    }
  end

  local top, bottom = split_groups(panes, 'y')

  if top and bottom then
    return {
      kind = 'split',
      direction = 'Bottom',
      first = build_layout(top),
      second = build_layout(bottom),
      first_bounds = bounds(top),
      second_bounds = bounds(bottom),
    }
  end

  return { kind = 'stack', panes = panes }
end

local function next_tmux_layout_spawn(workspace, tab_index, pane_counter)
  pane_counter.count = pane_counter.count + 1
  return workspace_tmux_pane_spawn(workspace, tab_index, pane_counter.count)
end

local function apply_layout(target_pane, node, workspace, tab_index, pane_counter)
  if not node or node.kind == 'pane' then
    return
  end

  if node.kind == 'split' then
    local total = node.direction == 'Right'
      and (node.first_bounds.cols + node.second_bounds.cols)
      or (node.first_bounds.rows + node.second_bounds.rows)
    local second_size = node.direction == 'Right' and node.second_bounds.cols or node.second_bounds.rows
    local percent = math.max(5, math.min(95, math.floor((second_size / total) * 100 + 0.5)))
    local split_args = {
      direction = node.direction,
      size = percent / 100,
    }
    local spawn = next_tmux_layout_spawn(workspace, tab_index, pane_counter)

    if spawn then
      for key, value in pairs(spawn) do
        split_args[key] = value
      end
    end

    local new_pane = target_pane:split(split_args)
    apply_layout(target_pane, node.first, workspace, tab_index, pane_counter)
    apply_layout(new_pane, node.second, workspace, tab_index, pane_counter)
    return
  end

  if node.kind == 'stack' then
    for index = 2, #node.panes do
      local split_args = { direction = 'Bottom', size = 0.5 }
      local spawn = next_tmux_layout_spawn(workspace, tab_index, pane_counter)

      if spawn then
        for key, value in pairs(spawn) do
          split_args[key] = value
        end
      end

      target_pane:split(split_args)
    end
  end
end

local function restore_workspace_in_new_window(window, pane, workspace)
  local first_tab = workspace.tabs[1]
  local ok, first_mux_tab, first_mux_pane, mux_window = pcall(function()
    return wezterm.mux.spawn_window(merge_spawn_options({
      position = { origin = 'ActiveScreen', x = 80, y = 80 },
    }, workspace_tmux_pane_spawn(workspace, 1, 1)))
  end)

  if not ok or not mux_window then
    append_debug('restore spawn_window failed name=' .. tostring(workspace.name) .. ' err=' .. tostring(first_mux_pane))
    notify_error(window, 'Impossible de restaurer le workspace: ' .. workspace.name)
    return false
  end

  append_debug('restore spawn_window ok name=' .. tostring(workspace.name))
  set_tab_title(first_mux_tab, first_tab.title)

  local layout_ok, layout_err = pcall(function()
    apply_layout(first_mux_pane, build_layout(first_tab.panes or {}), workspace, 1, { count = 1 })
  end)

  if not layout_ok then
    notify_error(window, 'Erreur layout: ' .. tostring(layout_err))
  end

  for index = 2, #workspace.tabs do
    local tab_snapshot = workspace.tabs[index]
    local new_tab, new_pane = mux_window:spawn_tab(
      merge_spawn_options({}, workspace_tmux_pane_spawn(workspace, index, 1))
    )

    set_tab_title(new_tab, tab_snapshot.title)

    pcall(function()
      apply_layout(new_pane, build_layout(tab_snapshot.panes or {}), workspace, index, { count = 1 })
    end)
  end

  focus_mux_window_soon(mux_window)

  return true
end

local function restore_layout_in_current_window(window, workspace)
  local first_tab = workspace.tabs[1]
  local ok, err = pcall(function()
    local mux_window = window:mux_window()

    if mux_window:get_workspace() ~= workspace.name then
      append_debug('restore current window skipped wrong workspace=' .. tostring(mux_window:get_workspace()))
      return
    end

    local first_mux_pane = mux_window:active_pane()
    set_tab_title(mux_window:active_tab(), first_tab.title)

    apply_layout(first_mux_pane, build_layout(first_tab.panes or {}), workspace, 1, { count = 1 })

    for index = 2, #workspace.tabs do
      local tab_snapshot = workspace.tabs[index]
      local new_tab, new_pane = mux_window:spawn_tab(
        merge_spawn_options({}, workspace_tmux_pane_spawn(workspace, index, 1))
      )

      set_tab_title(new_tab, tab_snapshot.title)
      apply_layout(new_pane, build_layout(tab_snapshot.panes or {}), workspace, index, { count = 1 })
    end
  end)

  if not ok then
    append_debug('restore current window layout failed: ' .. tostring(err))
    notify_error(window, 'Workspace ouvert, layout partiel: ' .. workspace.name)
  end
end

local function restore_workspace_in_current_window(window, pane, workspace)
  local first_tab = workspace.tabs[1]

  window:perform_action(
    wezterm.action.SwitchToWorkspace {
      name = workspace.name,
      spawn = workspace_tmux_pane_spawn(workspace, 1, 1),
    },
    pane
  )

  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(0.1, function()
      restore_layout_in_current_window(window, workspace)
    end)
  else
    restore_layout_in_current_window(window, workspace)
  end

  return true
end

local function restore_workspace(window, pane, workspace, mode)
  mode = mode or 'current'
  append_debug('restore start name=' .. tostring(workspace.name) .. ' mode=' .. tostring(mode))

  if mode == 'new' then
    if type(workspace.tabs) == 'table' and #workspace.tabs > 0 then
      if restore_workspace_in_new_window(window, pane, workspace) then
        append_debug('restore done new window name=' .. tostring(workspace.name))
      end

      return
    end

    local args = {}
    local spawn = tmux_workspace_spawn(workspace.name, 'tab1_pane1')

    if spawn then
      for key, value in pairs(spawn) do
        args[key] = value
      end
    end

    local ok, err = pcall(function()
      wezterm.mux.spawn_window(args)
    end)

    if ok then
      append_debug('restore legacy new window name=' .. tostring(workspace.name))
    else
      append_debug('restore legacy new window failed: ' .. tostring(err))
      notify_error(window, 'Impossible d ouvrir une nouvelle fenetre: ' .. workspace.name)
    end

    return
  end

  if workspace_exists(workspace.name) then
    append_debug('restore live switch name=' .. tostring(workspace.name))

    window:perform_action(wezterm.action.SwitchToWorkspace { name = workspace.name }, pane)
    notify(window, 'Workspace live rejoint: ' .. workspace.name)
    return
  end

  if type(workspace.tabs) ~= 'table' or #workspace.tabs == 0 then
    append_debug('restore legacy workspace name=' .. tostring(workspace.name))
    local args = { name = workspace.name }
    local spawn = tmux_workspace_spawn(workspace.name, 'tab1_pane1')

    if spawn then
      args.spawn = spawn
    end

    window:perform_action(wezterm.action.SwitchToWorkspace(args), pane)
    return
  end

  local restored = nil

  restored = restore_workspace_in_current_window(window, pane, workspace)

  if not restored then
    return
  end

  append_debug('restore done name=' .. tostring(workspace.name))
end

function M.prompt_new_workspace(window, pane)
  window:perform_action(
    wezterm.action.PromptInputLine {
      description = wezterm.format {
        { Attribute = { Intensity = 'Bold' } },
        { Foreground = { AnsiColor = 'Fuchsia' } },
        { Text = 'Nommer le nouveau Workspace: ' },
      },
      action = wezterm.action_callback(function(win, p, line)
        if line and line ~= '' then
          win:perform_action(wezterm.action.SwitchToWorkspace {
            name = line,
            spawn = tmux_workspace_spawn(line, 'tab1_pane1'),
          }, p)
        end
      end),
    },
    pane
  )
end

function M.save_current(window, pane, name)
  local workspace = canonical_workspace_name(name or workspace_name(window))
  append_debug('save_current called name=' .. tostring(workspace))

  local ok, snapshot_or_error = pcall(function()
    return capture_current_window(window, pane)
  end)

  if not ok then
    append_debug('capture failed: ' .. tostring(snapshot_or_error))
    notify_error(window, 'Erreur capture workspace: ' .. tostring(snapshot_or_error))
    return false
  end

  local snapshot = snapshot_or_error
  local saved_ok, saved_or_error = pcall(function()
    return upsert_workspace(workspace, snapshot)
  end)

  if not saved_ok or not saved_or_error then
    append_debug('save failed: ' .. tostring(saved_or_error))
    notify_error(window, 'Erreur ecriture workspace: ' .. tostring(saved_or_error))
    return false
  end

  local tab_count = type(snapshot.tabs) == 'table' and #snapshot.tabs or 0
  notify(window, 'Workspace enregistre: ' .. workspace .. ' (' .. tab_count .. ' tabs)')
  return true
end

function M.prompt_save_current(window, pane)
  append_debug('prompt_save_current called')
  window:perform_action(
    wezterm.action.PromptInputLine {
      description = wezterm.format {
        { Attribute = { Intensity = 'Bold' } },
        { Foreground = { AnsiColor = 'Fuchsia' } },
        { Text = 'Enregistrer le Workspace sous (' .. workspace_name(window) .. '): ' },
      },
      action = wezterm.action_callback(function(win, p, line)
        if line then
          local name = line ~= '' and line or workspace_name(win)
          M.save_current(win, p, name)
        end
      end),
    },
    pane
  )
end

function M.prompt_rename_active_tab(window, pane)
  local current_title = tab_title(active_tab(window)) or pane_title(pane) or ''

  window:perform_action(
    wezterm.action.PromptInputLine {
      description = wezterm.format {
        { Attribute = { Intensity = 'Bold' } },
        { Foreground = { AnsiColor = 'Fuchsia' } },
        { Text = 'Renommer le tab (' .. current_title .. '): ' },
      },
      action = wezterm.action_callback(function(win, p, line)
        if not line then
          return
        end

        local name = line ~= '' and line or current_title
        local tab = active_tab(win)

        if not tab then
          notify_error(win, 'Tab actif introuvable')
          return
        end

        set_tab_title(tab, name)
        M.save_current(win, p)
      end),
    },
    pane
  )
end

function M.choose_registered(window, pane, mode)
  local registry = load_registry()
  local choices = {}
  local title = 'Ouvrir un workspace ici'

  if mode == 'new' then
    title = 'Ouvrir un workspace en nouvelle fenetre'
  end

  for _, workspace in ipairs(registered_workspaces(registry)) do
    table.insert(choices, {
      id = workspace.name,
      label = workspace.name,
    })
  end

  if #choices == 0 then
    notify(window, 'Aucun workspace enregistre.')
    return
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = title,
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(win, p, id, label)
        local name = id or label

        if name then
          append_debug('selector selected name=' .. tostring(name) .. ' mode=' .. tostring(mode))
          local selected = find_workspace(load_registry(), name)

          if selected then
            restore_workspace(win, p, selected, mode)
          else
            append_debug('selector missing workspace name=' .. tostring(name))
            notify_error(win, 'Workspace introuvable: ' .. tostring(name))
          end
        end
      end),
    },
    pane
  )
end

function M.choose_delete_registered(window, pane)
  local registry = load_registry()
  local choices = {}

  for _, workspace in ipairs(registered_workspaces(registry)) do
    table.insert(choices, {
      id = workspace.name,
      label = workspace.name,
    })
  end

  if #choices == 0 then
    notify(window, 'Aucun workspace enregistre.')
    return
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = 'Supprimer un workspace',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(win, _, id, label)
        local name = id or label

        if not name then
          return
        end

        local ok, removed = pcall(function()
          return remove_workspace(name)
        end)

        if ok and removed then
          append_debug('delete workspace name=' .. tostring(name))
          notify(win, 'Workspace supprime: ' .. name)
        else
          append_debug('delete failed name=' .. tostring(name) .. ' err=' .. tostring(removed))
          notify_error(win, 'Impossible de supprimer: ' .. name)
        end
      end),
    },
    pane
  )
end

function M.activate_relative(window, pane, offset)
  local registry = load_registry()
  local workspaces = registered_workspaces(registry)

  if #workspaces == 0 then
    notify(window, 'Aucun workspace enregistre.')
    return
  end

  local _, index = find_workspace({ workspaces = workspaces }, canonical_workspace_name(workspace_name(window)))

  if not index then
    index = offset > 0 and 0 or 1
  end

  local next_index = ((index - 1 + offset) % #workspaces) + 1
  restore_workspace(window, pane, workspaces[next_index])
end

return M
