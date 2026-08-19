local wezterm = require 'wezterm'
local domains = require 'lua/domains'
local notifications = require 'lua/notify'
local M = {}

-- Etat runtime (registre + journal) : DELIBEREMENT hors de `wezterm.config_dir`.
--
-- WezTerm surveille son repertoire de config et recharge TOUTE la configuration
-- a la moindre ecriture dedans, y compris sur un fichier qui n'est pas du Lua.
-- Mesure le 2026-08-18 : une seule ligne ajoutee au journal declenche 3
-- reevaluations de la config. Chaque restauration (3 lignes) et chaque
-- sauvegarde en provoquait donc autant. Or un rechargement invalide l'etat de
-- rendu : les panes servis par un mux-server (`localmux` comme `vibe`) doivent
-- re-recuperer leurs lignes et s'affichent ENTIEREMENT EN BLOCS en attendant.
-- C'est LA cause du bug « carres » — ni le front-end graphique ni le reseau n'y
-- sont pour quelque chose. Il tue aussi les timers en vol, donc la boucle
-- d'auto-sauvegarde.
--
-- Directement dans `home_dir` et pas dans un sous-repertoire : Lua ne sait pas
-- creer un repertoire sans lancer un shell. Meme convention que `~/.wezterm-tls`.
--
-- NE JAMAIS REMETTRE ICI UN FICHIER ECRIT EN COURS DE SESSION.
local registry_path = wezterm.home_dir .. '/.wezterm-workspaces.json'
local debug_path = wezterm.home_dir .. '/.wezterm-workspaces.log'
-- Ancien emplacement, relu UNE fois pour reprendre le registre existant.
local legacy_registry_path = wezterm.config_dir .. '/workspaces.json'
local snapshot_version = 1

local notify = notifications.info
local notify_error = notifications.error

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

-- Commandes qu'on ne rejoue JAMAIS au restore : soit triviales (elles ecrasent
-- l'intention utile sans rien apporter), soit dangereuses. `wezterm-mux-server`
-- en est le cas critique : un pane du snapshot le portait en `last_command`
-- (cf. workspaces.json), le rejouer relancerait un mux-server dans un pane.
-- Comparaison sur le premier token, basename sans extension, en minuscules.
local non_replayable_commands = {
  cd = true,
  clear = true,
  cls = true,
  exit = true,
  la = true,
  ll = true,
  logout = true,
  ls = true,
  pwd = true,
  ['wezterm-mux-server'] = true,
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

-- Reprise du registre laisse dans l'ancien emplacement. Copie unique : l'ancien
-- fichier est laisse en place (il ne gene plus des lors que personne n'y ecrit),
-- ce qui laisse aussi un filet si la nouvelle ecriture echoue.
local function migrate_state_location()
  if read_file(registry_path) then
    return
  end

  local legacy = read_file(legacy_registry_path)

  if legacy and legacy ~= '' then
    write_file(registry_path, legacy)
  end
end

migrate_state_location()

local function append_debug(message)
  local file = io.open(debug_path, 'a')

  if not file then
    return
  end

  file:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. tostring(message) .. '\n')
  file:close()
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

local function save_registry(registry)
  return write_file(registry_path, wezterm.json_encode(normalize_registry(registry)))
end

-- Reecrit en profondeur tout `domain = 'local'` vers le mux local. Recursif : le
-- champ existe au niveau du workspace ET de chaque pane, a n'importe quelle
-- profondeur (tabs, arbres de splits). Rien ne doit rester sur le domaine
-- integre, qui ne survit pas a la fermeture de la fenetre.
local function migrate_local_to_mux(node)
  if type(node) ~= 'table' then
    return false
  end

  local changed = false

  for key, value in pairs(node) do
    if key == 'domain' and value == domains.LOCAL then
      node[key] = domains.LOCAL_MUX
      changed = true
    elseif type(value) == 'table' and migrate_local_to_mux(value) then
      changed = true
    end
  end

  return changed
end

-- Deux migrations idempotentes, appliquees au chargement du registre :
--   - entrees anterieures a la gestion multi-domaines : pas de champ `domain`,
--     toutes capturees sur le mux distant (seul domaine existant alors). Sans ce
--     report, elles se restaureraient en local (repli 'DefaultDomain') ;
--   - entrees capturees sur le domaine integre `local`, qui ne persiste rien :
--     elles passent au mux local (cf. domains.persisted, qui tient le meme role
--     a la capture).
-- Reecrites une seule fois, ensuite chaque upsert porte le bon domaine.
local function migrate_domains(registry)
  local changed = false

  for _, workspace in ipairs(registry.workspaces) do
    if not domains.normalize(workspace.domain) then
      workspace.domain = domains.REMOTE
      changed = true
    end

    if migrate_local_to_mux(workspace) then
      changed = true
    end
  end

  return changed
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

  local registry = normalize_registry(decoded)

  if migrate_domains(registry) then
    append_debug('migration domaine appliquee sur ' .. registry_path)
    save_registry(registry)
  end

  return registry
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

-- Normalise un token de commande vers sa forme de comparaison : basename, sans
-- extension .exe, en minuscules (ex: 'C:\...\Wezterm-Mux-Server.exe' -> 'wezterm-mux-server').
local function normalized_command_word(word)
  if type(word) ~= 'string' or word == '' then
    return nil
  end

  return (basename(word):gsub('%.exe$', ''):lower())
end

-- true si `command` peut etre rejouee au restore : non vide, sur une seule
-- ligne, et dont le premier mot n'est pas dans la denylist.
local function is_replayable_command(command)
  if type(command) ~= 'string' or command == '' or command:find('[\r\n]') then
    return false
  end

  local first = command:match('^%s*(%S+)')
  local word = normalized_command_word(first)

  return word ~= nil and not non_replayable_commands[word]
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

-- Normalise un chemin de travail remonte par un pane distant Windows
-- (ex: 'file://host/C:/Users/x', '/C:/Users/x') vers une forme Windows 'C:\Users\x'.
local function normalize_remote_path(path)
  if type(path) ~= 'string' or path == '' then
    return path
  end

  path = path:gsub('^file://[^/]*', '')

  local drive_rest = path:match('^/([A-Za-z]:.*)$')

  if drive_rest then
    path = drive_rest
  end

  return (path:gsub('/', '\\'))
end

local function current_working_dir(pane)
  -- Protege : si le pane disparait entre l'enumeration et cette lecture (pane
  -- ephemere, process qui se ferme), l'exception ne doit pas remonter et faire
  -- tomber la capture entiere du workspace.
  local ok, cwd = pcall(function()
    return pane:get_current_working_dir()
  end)

  if not ok then
    return nil
  end

  if type(cwd) == 'userdata' and (not cwd.scheme or cwd.scheme == 'file') and cwd.file_path then
    return normalize_remote_path(cwd.file_path)
  end

  if type(cwd) == 'string' then
    local ok, parsed = false, nil

    if wezterm.url and wezterm.url.parse then
      ok, parsed = pcall(wezterm.url.parse, cwd)
    end

    if ok and parsed and (not parsed.scheme or parsed.scheme == 'file') and parsed.file_path then
      return normalize_remote_path(parsed.file_path)
    end

    return normalize_remote_path(cwd:gsub('^file://', ''))
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
    return normalize_remote_path(cwd)
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

-- L'archivage est un masquage doux et reversible : un marqueur `archived_at`
-- (horodatage ISO, meme format que `saved_at`) retire le workspace des listes
-- du quotidien sans rien supprimer. Absence du champ = workspace actif.
local function is_archived(workspace)
  return type(workspace) == 'table' and workspace.archived_at ~= nil
end

-- filter: 'active' (defaut) | 'archived' | 'all'
local function list_workspaces(registry, filter)
  filter = filter or 'active'
  local result = {}

  for _, workspace in ipairs(registry.workspaces) do
    local archived = is_archived(workspace)

    if filter == 'all'
      or (filter == 'archived' and archived)
      or (filter == 'active' and not archived) then
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

local function set_workspace_archived(name, archived)
  local registry = load_registry()
  local workspace = find_workspace(registry, name)

  if not workspace then
    return false
  end

  if archived then
    workspace.archived_at = os.date('!%Y-%m-%dT%H:%M:%SZ')
  else
    workspace.archived_at = nil
  end

  return save_registry(registry)
end

local function upsert_workspace(name, snapshot)
  append_debug('upsert start name=' .. tostring(name))
  local registry = load_registry()
  local existing = find_workspace(registry, name)
  snapshot.name = name

  if existing then
    -- L'etat d'archivage vit dans le registre, pas dans le snapshot capture :
    -- le preserver, sinon un simple ALT+r (enregistrer) l'effacerait.
    if existing.archived_at ~= nil and snapshot.archived_at == nil then
      snapshot.archived_at = existing.archived_at
    end

    -- Meme raisonnement pour le domaine : une capture faite sur des panes morts
    -- (mux-server redemarre) ne remonte aucun domaine. Retomber sur le defaut
    -- ramenerait un workspace distant en local a la restauration suivante.
    if domains.normalize(existing.domain) and not domains.normalize(snapshot.domain) then
      snapshot.domain = existing.domain
    end

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

-- `fallback_domain` : domaine du workspace, utilise quand le pane n'en porte pas
-- (snapshot anterieur au multi-domaines, ou capture sur pane mort).
local function pane_spawn(pane_snapshot, fallback_domain)
  if type(pane_snapshot) ~= 'table' then
    return nil
  end

  local cwd = normalize_remote_path(pane_snapshot.cwd)
  local argv = copy_array(pane_snapshot.argv)
  local command = type(pane_snapshot.last_command) == 'string' and pane_snapshot.last_command or nil
  local domain = domains.normalize(pane_snapshot.domain) or domains.normalize(fallback_domain)
  local spawn = {}

  if domain then
    spawn.domain = domains.spawn_domain(domain)
  end

  if argv and (argv[1]:match('^%-%-') or pane_snapshot.title == 'wslhost.exe'
    or non_replayable_commands[normalized_command_word(argv[1]) or '']) then
    argv = nil
  end

  if not is_replayable_command(command) then
    command = nil
  end

  if type(cwd) == 'string' and cwd ~= '' then
    spawn.cwd = cwd
  end

  -- Relance de `last_command` en gardant un shell interactif. Le shell doit
  -- exister sur la machine du pane, d'ou la distinction local/distant :
  --   - distant : `powershell.exe` en dur (on ne peut pas sonder ce qui est
  --     installe sur vibe, et il est present sur tout Windows) ; son profil y
  --     charge deja le workspace tracker ;
  --   - local : `domains.local_prog`, qui ajoute l'integration OSC 7 au shell
  --     resolu — un pane restaure doit annoncer son cwd comme les autres, sinon
  --     ses propres splits repartiraient du HOME. Retourne nil hors Windows
  --     (`-NoExit -Command` est une syntaxe PowerShell) : on retombe alors sur
  --     l'argv capture.
  local replay_args = nil

  if command then
    if domains.is_remote(domain) then
      replay_args = { 'powershell.exe', '-NoExit', '-Command', command }
    else
      replay_args = domains.local_prog(command)
    end
  end

  if replay_args then
    spawn.args = replay_args
  elseif argv and not is_shell(argv) then
    spawn.args = argv
  end

  if spawn.cwd or spawn.args or spawn.domain then
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

-- Spawn epingle sur le domaine DU WORKSPACE (local ou distant selon ce qui a ete
-- capture), avec repli sur le domaine par defaut de la fenetre.
--
-- Un domaine explicite est indispensable des qu'un SwitchToWorkspace est declenche
-- depuis le callback d'un selecteur ou d'un prompt : le `pane` fourni a ce callback
-- est le pane d'OVERLAY (TermWizTerminalPane). Sans `domain`, WezTerm resout
-- `CurrentPaneDomain` vers `TermWizTerminalDomain` et refuse le spawn ("cannot
-- spawn panes in a TermWizTerminalPane") : le workspace s'ouvrait alors sans
-- aucun pane.
--
-- Table neuve a chaque appel : merge_spawn_options ecrit dans `base`.
local function workspace_domain_spawn(workspace)
  return { domain = domains.spawn_domain(workspace and workspace.domain) }
end

local function merge_spawn_options(base, spawn)
  if spawn then
    for key, value in pairs(spawn) do
      base[key] = value
    end
  end

  return base
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

-- Fenetres mux portant ce workspace (souvent zero : le nom peut exister dans
-- wezterm.mux.get_workspace_names() sans aucune fenetre).
local function workspace_mux_windows(name)
  local windows = {}

  if not wezterm.mux or not wezterm.mux.all_windows then
    return windows
  end

  for _, mux_window in ipairs(wezterm.mux.all_windows()) do
    local ok, workspace = pcall(function()
      return mux_window:get_workspace()
    end)

    if ok and workspace == name then
      table.insert(windows, mux_window)
    end
  end

  return windows
end

-- Compte les panes reellement presents dans les fenetres du workspace, et
-- journalise l'etat vu du mux. Necessaire car un workspace « ouvert mais vide »
-- (fenetre sans tab, ou coquille laissee par un mux-server redemarre) doit
-- pouvoir etre restaure : se fier au seul nom, ou a la seule presence d'une
-- fenetre, bloquait sa propre restauration (« Workspaces restaures: 0/3 »).
local function workspace_pane_count(name)
  local windows = workspace_mux_windows(name)
  local tab_count, pane_count = 0, 0

  for _, mux_window in ipairs(windows) do
    local ok, tabs = pcall(function()
      return mux_window:tabs()
    end)

    if ok and type(tabs) == 'table' then
      tab_count = tab_count + #tabs

      for _, tab in ipairs(tabs) do
        local ok_panes, panes = pcall(function()
          return tab:panes()
        end)

        if ok_panes and type(panes) == 'table' then
          pane_count = pane_count + #panes
        end
      end
    end
  end

  append_debug('workspace state name=' .. tostring(name)
    .. ' windows=' .. #windows .. ' tabs=' .. tab_count .. ' panes=' .. pane_count)

  return pane_count
end

-- Vivant = au moins un pane. Un workspace connu du mux mais sans aucun pane est
-- une coquille : on le restaure au lieu de le sauter.
local function workspace_is_live(name)
  return workspace_pane_count(name) > 0
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

-- Capture d'un seul pane. Isolee dans son propre pcall par l'appelant : un pane
-- mort (course : fermeture, process qui sort avec exit_behavior='Close') doit
-- etre ignore, pas faire tomber la capture des autres panes du workspace.
local function capture_pane(item)
  local p = item.pane
  local rect = pane_rect(item)
  local argv = pane_process_argv(p)
  local command = argv and table.concat(argv, ' ') or nil
  local title = pane_title(p)
  local tracked_cwd = pane_user_var(p, 'WEZTERM_WORKSPACE_CWD')
  local last_command = pane_user_var(p, 'WEZTERM_WORKSPACE_LAST_COMMAND')
  local cwd = tracked_cwd or cwd_from_title(title) or current_working_dir(p)
  -- `persisted` et non `pane_domain` brut : un pane capture dans le domaine
  -- integre (session de repli, mux local indisponible au demarrage) doit
  -- revenir dans le mux local a la restauration. Le registre ne contient donc
  -- jamais `local`.
  local domain = domains.persisted(domains.pane_domain(p))

  if argv and (argv[1]:match('^%-%-') or title == 'wslhost.exe') then
    argv = nil
    command = nil
  end

  return {
    cwd = cwd,
    argv = argv,
    command = command,
    last_command = last_command,
    domain = domain,
    title = title,
    x = rect.x,
    y = rect.y,
    cols = rect.cols,
    rows = rect.rows,
    is_active = item.is_active == true,
  }
end

-- Domaine du workspace : celui du pane actif, sinon le premier domaine trouve
-- parmi les panes captures. Un workspace peut theoriquement melanger les
-- domaines (chaque pane garde le sien) ; ce champ sert de repli et d'etiquette
-- dans les selecteurs.
local function snapshot_domain(tabs, active_pane)
  local from_active = active_pane and domains.persisted(domains.pane_domain(active_pane))

  if from_active then
    return from_active
  end

  for _, tab in ipairs(tabs) do
    for _, pane in ipairs(tab.panes) do
      if domains.normalize(pane.domain) then
        return pane.domain
      end
    end
  end

  return nil
end

local function capture_mux_window(mux_window, active_pane)
  append_debug('capture start')
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
      local ok_pane, pane = pcall(capture_pane, item)

      if ok_pane and type(pane) == 'table' then
        table.insert(panes, pane)
      else
        append_debug('pane capture skipped: ' .. tostring(pane))
      end
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
    domain = snapshot_domain(tabs, active_pane),
    tabs = tabs,
    saved_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }

  append_debug('capture done tabs=' .. tostring(#tabs))
  return snapshot
end

local function capture_current_window(window, active_pane)
  return capture_mux_window(window:mux_window(), active_pane)
end

-- Intervalle de l'auto-sauvegarde (secondes). Rafraichit les snapshots des
-- workspaces DEJA enregistres pour que le « tout restaurer » (ALT+Shift+R) apres
-- un redemarrage du mux-server reparte d'un etat recent, pas d'un vieux ALT+r.
local auto_save_interval = 60

-- Un snapshot « avec contenu » a au moins un pane portant un cwd reel ou un
-- argv. Garde-fou de l'auto-save : apres un redemarrage du mux-server, les panes
-- morts sont filtres (pcall par pane) et le snapshot devient vide ; on refuse
-- alors d'ecraser une bonne sauvegarde par du vide.
local function snapshot_has_content(snapshot)
  if type(snapshot) ~= 'table' or type(snapshot.tabs) ~= 'table' then
    return false
  end

  for _, tab in ipairs(snapshot.tabs) do
    if type(tab.panes) == 'table' then
      for _, pane in ipairs(tab.panes) do
        if (type(pane.cwd) == 'string' and pane.cwd ~= '')
          or (type(pane.argv) == 'table' and #pane.argv > 0) then
          return true
        end
      end
    end
  end

  return false
end

-- Rafraichit les snapshots des workspaces DEJA presents dans le registre a
-- partir de leurs fenetres mux vivantes. Ne CREE jamais d'entree (les nouveaux
-- workspaces restent crees a la main via ALT+r) et n'ecrase jamais avec du vide
-- (snapshot_has_content). upsert_workspace preserve `archived_at`.
local function refresh_saved_workspaces()
  if not wezterm.mux or not wezterm.mux.all_windows then
    return
  end

  local known = {}

  for _, workspace in ipairs(load_registry().workspaces) do
    known[workspace.name] = true
  end

  for _, mux_window in ipairs(wezterm.mux.all_windows()) do
    local ok, name = pcall(function()
      return canonical_workspace_name(mux_window:get_workspace())
    end)

    if ok and known[name] then
      local captured, snapshot = pcall(capture_mux_window, mux_window, nil)

      if captured and snapshot_has_content(snapshot) then
        pcall(upsert_workspace, name, snapshot)
      end
    end
  end
end

-- Generation et battement de coeur de la boucle vivante, dans `wezterm.GLOBAL`
-- pour survivre aux rechargements de config (qui reconstruisent tout l'etat Lua).
local auto_save_generation_flag = 'workspace_auto_save_generation'
local auto_save_heartbeat_flag = 'workspace_auto_save_heartbeat'
-- Sans battement depuis 3 scrutations, la boucle est declaree morte et rearmee.
-- Large expres : une tick lente ne doit pas creer de doublon.
local auto_save_liveness_timeout = 3 * auto_save_interval

local function auto_save_tick(generation)
  -- Une boucle plus recente a pris le relais : celle-ci s'arrete, sinon les deux
  -- scruteraient en parallele.
  if wezterm.GLOBAL[auto_save_generation_flag] ~= generation then
    return
  end

  wezterm.GLOBAL[auto_save_heartbeat_flag] = os.time()

  local ok, err = pcall(refresh_saved_workspaces)

  if not ok then
    append_debug('auto-save erreur: ' .. tostring(err))
  end

  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(auto_save_interval, function()
      auto_save_tick(generation)
    end)
  end
end

-- Amorce la boucle si aucune ne bat. Idempotent et bon marche : appelable a
-- chaque `update-status` pour le prix d'une lecture de GLOBAL.
--
-- Un reload de config TUE les timers en vol, et sur ce depot il y en a a chaque
-- ecriture dans `config_dir` — ou vit justement `workspaces.json`. Une boucle
-- armee une seule fois est donc une boucle morte : d'ou le battement de coeur
-- plutot qu'un drapeau « demarree » definitif.
local function arm_auto_save()
  if not (wezterm.time and wezterm.time.call_after) then
    return
  end

  local heartbeat = wezterm.GLOBAL[auto_save_heartbeat_flag]

  if type(heartbeat) == 'number' and (os.time() - heartbeat) < auto_save_liveness_timeout then
    return
  end

  local generation = (tonumber(wezterm.GLOBAL[auto_save_generation_flag]) or 0) + 1

  wezterm.GLOBAL[auto_save_generation_flag] = generation
  wezterm.GLOBAL[auto_save_heartbeat_flag] = os.time()
  append_debug('auto-save armee generation=' .. generation .. ' cadence=' .. auto_save_interval .. 's')

  wezterm.time.call_after(auto_save_interval, function()
    auto_save_tick(generation)
  end)
end

-- ---------------------------------------------------------------------------
-- Prechargement des connexions, une fois par process
--
-- Rattache les domaines dont les workspaces ACTIFS ont besoin, pour que leurs
-- sessions soient deja la quand on bascule dessus au lieu d'etre rattachees dans
-- l'urgence d'une frappe. `domains.preload` sonde avant de rattacher : il ne
-- demarre pas le mux local s'il est eteint et ne touche pas a un serveur distant
-- qui ne repond pas, donc aucun risque de gel.
--
-- Le delai laisse la premiere fenetre s'afficher : meme court, un probe reste du
-- travail synchrone sur le thread GUI.
local preload_flag = 'workspace_preload_done'
local preload_delay = 1

local function preload_domains()
  local seen = {}

  for _, workspace in ipairs(list_workspaces(load_registry(), 'active')) do
    local domain = domains.normalize(workspace.domain)

    if domain and not seen[domain] then
      seen[domain] = true
      local ok, reason = domains.preload(domain)
      append_debug('prechargement domaine=' .. domain
        .. ' ok=' .. tostring(ok) .. ' (' .. tostring(reason) .. ')')
    end
  end
end

local function run_preload_once()
  if wezterm.GLOBAL[preload_flag] then
    return
  end

  wezterm.GLOBAL[preload_flag] = true

  if not (wezterm.time and wezterm.time.call_after) then
    return
  end

  wezterm.time.call_after(preload_delay, function()
    local ok, err = pcall(preload_domains)

    if not ok then
      append_debug('prechargement erreur: ' .. tostring(err))
    end
  end)
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

local function build_tab_layout(tab_snapshot)
  local panes = {}

  if type(tab_snapshot) ~= 'table' or type(tab_snapshot.panes) ~= 'table' then
    return nil
  end

  for _, pane in ipairs(tab_snapshot.panes) do
    local copy = {}

    for key, value in pairs(pane) do
      copy[key] = value
    end

    table.insert(panes, copy)
  end

  return build_layout(panes)
end

local function layout_pane_spawn(pane_snapshot, workspace)
  return pane_spawn(pane_snapshot, workspace and workspace.domain)
end

local function first_layout_spawn(workspace, _, layout)
  return layout_pane_spawn(first_leaf_pane(layout), workspace)
end

local function apply_layout(target_pane, node, workspace, tab_index)
  if not node or node.kind == 'pane' then
    return
  end

  if node.kind == 'split' then
    local total = node.direction == 'Right'
      and (node.first_bounds.cols + node.second_bounds.cols)
      or (node.first_bounds.rows + node.second_bounds.rows)
    local second_size = node.direction == 'Right' and node.second_bounds.cols or node.second_bounds.rows
    -- RATIO, jamais une taille absolue : la coupe doit suivre la fenetre du
    -- moment, pas celle qui a ete capturee. Un workspace enregistre en 159
    -- colonnes doit se rouvrir aux memes PROPORTIONS dans une fenetre plus
    -- petite.
    --
    -- Le `+ 0.005` compense le `floor` que WezTerm applique cote Rust
    -- (`SplitSize::Percent((size * 100.).floor())`) : sans lui, un pourcentage
    -- entier dont la representation flottante tombe juste en dessous (0.29 ->
    -- 28.999...) perdait un point a chaque restauration.
    local percent = math.max(5, math.min(95, math.floor((second_size / total) * 100 + 0.5)))
    local split_args = {
      direction = node.direction,
      size = (percent + 0.005) / 100,
    }
    local spawn = layout_pane_spawn(first_leaf_pane(node.second), workspace)

    if spawn then
      for key, value in pairs(spawn) do
        split_args[key] = value
      end
    end

    local new_pane = target_pane:split(split_args)
    apply_layout(target_pane, node.first, workspace, tab_index)
    apply_layout(new_pane, node.second, workspace, tab_index)
    return
  end

  if node.kind == 'stack' then
    for index = 2, #node.panes do
      local split_args = { direction = 'Bottom', size = 0.5 }
      local spawn = layout_pane_spawn(node.panes[index], workspace)

      if spawn then
        for key, value in pairs(spawn) do
          split_args[key] = value
        end
      end

      target_pane:split(split_args)
    end
  end
end


-- `mux_window` est fournie par l'appelant, qui vient de la creer : ne JAMAIS la
-- redemander a `window:mux_window()`, qui reste fige sur la fenetre mux d'avant
-- la bascule (cf. l'entree correspondante des guidelines).
local function restore_layout_in_window(window, mux_window, workspace)
  local first_tab = workspace.tabs[1]
  local first_layout = build_tab_layout(first_tab)
  local ok, err = pcall(function()
    local first_mux_pane = mux_window:active_pane()
    set_tab_title(mux_window:active_tab(), first_tab.title)

    apply_layout(first_mux_pane, first_layout, workspace, 1)

    for index = 2, #workspace.tabs do
      local tab_snapshot = workspace.tabs[index]
      local tab_layout = build_tab_layout(tab_snapshot)
      local new_tab, new_pane = mux_window:spawn_tab(
        merge_spawn_options({}, first_layout_spawn(workspace, index, tab_layout))
      )

      set_tab_title(new_tab, tab_snapshot.title)
      apply_layout(new_pane, tab_layout, workspace, index)
    end
  end)

  if not ok then
    append_debug('restore current window layout failed: ' .. tostring(err))
    notify_error(window, 'Workspace ouvert, layout partiel: ' .. workspace.name)
  end
end

-- Construit la fenetre du workspace PUIS bascule dessus. L'ordre est le fond du
-- probleme, pas un detail :
--
-- `SwitchToWorkspace { spawn = ... }` cree la fenetre EN DIFFERE. Entre la
-- bascule et l'arrivee de cette fenetre, le GUI a deja detruit celle du
-- workspace quitte et n'a plus rien a afficher : il se retrouve SANS AUCUNE
-- FENETRE, process vivant mais invisible. Mesure le 2026-08-19 a 21:28:45 —
-- `fenetres=0` avec deux process GUI en vie — apres quoi l'utilisateur relance
-- WezTerm, d'ou des instances qui s'accumulent (3 process pour une fenetre).
--
-- `wezterm.mux.spawn_window` est SYNCHRONE : il rend la fenetre, l'onglet et le
-- pane immediatement. On peut donc poser toute la disposition avant que le GUI
-- ne bascule, et il trouve une fenetre prete au lieu du vide. Corollaire : plus
-- besoin d'attendre quoi que ce soit ensuite.
local function restore_workspace_in_current_window(window, pane, workspace)
  local ok, first_tab, first_pane, mux_window = pcall(function()
    return wezterm.mux.spawn_window(merge_spawn_options({
      workspace = workspace.name,
      domain = domains.spawn_domain(workspace.domain),
    }, first_layout_spawn(workspace, 1, build_tab_layout(workspace.tabs[1]))))
  end)

  if not ok or not mux_window then
    append_debug('restore spawn_window failed name=' .. tostring(workspace.name)
      .. ' err=' .. tostring(first_tab))
    notify_error(window, 'Impossible d ouvrir le workspace: ' .. workspace.name)
    return false
  end

  restore_layout_in_window(window, mux_window, workspace, first_tab, first_pane)

  window:perform_action(
    wezterm.action.SwitchToWorkspace { name = workspace.name },
    pane
  )

  return true
end

local function restore_workspace(window, pane, workspace)
  append_debug('restore start name=' .. tostring(workspace.name)
    .. ' domain=' .. tostring(workspace.domain))

  -- Un domaine mux detache refuse tout spawn : le rattacher AVANT de restaurer,
  -- sinon le workspace s'ouvre vide. Le premier workspace distant ouvert depuis
  -- une session locale passe systematiquement par ici.
  local attached, attach_err = domains.ensure_attached(workspace.domain)

  if not attached then
    append_debug('restore attach failed name=' .. tostring(workspace.name) .. ' err=' .. tostring(attach_err))
    notify_error(window, 'Domaine ' .. domains.label(workspace.domain) .. ' injoignable: ' .. workspace.name)
    return
  end

  -- PAS de mode « nouvelle fenetre ». Invariant du depot : une seule fenetre
  -- ouverte a la fois. Un workspace s'ouvre la ou on est — WezTerm y revele la
  -- fenetre du workspace cible — jamais a cote.
  if workspace_is_live(workspace.name) then
    append_debug('restore live switch name=' .. tostring(workspace.name))

    window:perform_action(wezterm.action.SwitchToWorkspace { name = workspace.name }, pane)
    notify(window, 'Workspace live rejoint: ' .. workspace.name)
    return
  end

  if type(workspace.tabs) ~= 'table' or #workspace.tabs == 0 then
    append_debug('restore legacy workspace name=' .. tostring(workspace.name))
    window:perform_action(
      wezterm.action.SwitchToWorkspace {
        name = workspace.name,
        spawn = workspace_domain_spawn(workspace),
      },
      pane
    )
    return
  end

  local restored = nil

  restored = restore_workspace_in_current_window(window, pane, workspace)

  if not restored then
    return
  end

  append_debug('restore done name=' .. tostring(workspace.name))
end

-- Nom puis domaine : c'est a la creation qu'on decide si le workspace vit sur ce
-- PC ou sur le serveur. Le domaine n'est pas devine depuis le pane courant, sinon
-- creer un workspace distant depuis une fenetre locale imposerait d'y basculer
-- d'abord. Il sera fige dans le registre au premier ALT+r.
function M.prompt_new_workspace(window, pane)
  window:perform_action(
    wezterm.action.PromptInputLine {
      description = wezterm.format {
        { Attribute = { Intensity = 'Bold' } },
        { Foreground = { AnsiColor = 'Fuchsia' } },
        { Text = 'Nommer le nouveau Workspace: ' },
      },
      action = wezterm.action_callback(function(win, p, line)
        if not line or line == '' then
          return
        end

        -- Le pane d'overlay du prompt vient d'etre ferme : repartir du pane
        -- actif de la fenetre pour ouvrir le selecteur suivant.
        local host_pane = win:active_pane() or p

        domains.choose(win, host_pane, 'Domaine du workspace ' .. line, function(w, sel_pane, domain)
          local ok, err = domains.ensure_attached(domain)

          if not ok then
            notify_error(w, 'Domaine ' .. domains.label(domain) .. ' injoignable: ' .. tostring(err))
            return
          end

          w:perform_action(wezterm.action.SwitchToWorkspace {
            name = line,
            spawn = { domain = domains.spawn_domain(domain) },
          }, sel_pane)

          notify(w, 'Workspace ' .. line .. ' [' .. domains.label(domain) .. ']')
        end)
      end),
    },
    pane
  )
end

function M.split_pane(window, pane, direction)
  -- `CurrentPaneDomain` explicite : un split doit rester sur la machine du pane
  -- qu'il divise. La persistance est assuree cote mux-server, local comme
  -- distant (plus besoin de session tmux).
  local ok, err = pcall(function()
    pane:split { direction = direction, domain = 'CurrentPaneDomain' }
  end)

  if not ok then
    append_debug('split failed: ' .. tostring(err))
    notify_error(window, 'Impossible d ouvrir un pane')
  end
end

function M.spawn_tab(window)
  local mux_window = window:mux_window()
  -- `CurrentPaneDomain` et non le defaut de la fenetre : dans un workspace
  -- distant ouvert depuis une fenetre restee locale par defaut, un nouveau tab
  -- doit suivre le workspace, pas le defaut.
  local ok, err = pcall(function()
    mux_window:spawn_tab { domain = 'CurrentPaneDomain' }
  end)

  if not ok then
    append_debug('spawn tab failed: ' .. tostring(err))
    notify_error(window, 'Impossible d ouvrir un tab')
  end
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
  notify(window, 'Workspace enregistre: ' .. workspace
    .. ' [' .. domains.label(snapshot.domain) .. '] (' .. tab_count .. ' tabs)')
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

-- Libelle de selecteur : nom + domaine. Le domaine est la seule facon de
-- distinguer d'un coup d'oeil un workspace local d'un workspace distant, et il
-- reste filtrable au clavier (recherche fuzzy sur « vibe » ou « local »).
local function workspace_choice_label(workspace, suffix)
  return workspace.name .. '  [' .. domains.label(workspace.domain) .. ']' .. (suffix or '')
end

function M.choose_registered(window, pane)
  local registry = load_registry()
  local choices = {}
  local title = 'Ouvrir un workspace'

  for _, workspace in ipairs(list_workspaces(registry, 'active')) do
    table.insert(choices, {
      id = workspace.name,
      label = workspace_choice_label(workspace),
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
          append_debug('selector selected name=' .. tostring(name))
          local selected = find_workspace(load_registry(), name)

          if selected then
            restore_workspace(win, p, selected)
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

  for _, workspace in ipairs(list_workspaces(registry, 'all')) do
    local suffix = is_archived(workspace) and '  (archive)' or ''
    table.insert(choices, {
      id = workspace.name,
      label = workspace_choice_label(workspace, suffix),
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

function M.choose_archive(window, pane)
  local registry = load_registry()
  local choices = {}

  for _, workspace in ipairs(list_workspaces(registry, 'active')) do
    table.insert(choices, {
      id = workspace.name,
      label = workspace_choice_label(workspace),
    })
  end

  if #choices == 0 then
    notify(window, 'Aucun workspace actif a archiver.')
    return
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = 'Archiver un workspace',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(win, _, id, label)
        local name = id or label

        if not name then
          return
        end

        local ok, done = pcall(function()
          return set_workspace_archived(name, true)
        end)

        if ok and done then
          append_debug('archive workspace name=' .. tostring(name))
          notify(win, 'Workspace archive: ' .. name)
        else
          append_debug('archive failed name=' .. tostring(name) .. ' err=' .. tostring(done))
          notify_error(win, 'Impossible d archiver: ' .. name)
        end
      end),
    },
    pane
  )
end

function M.choose_unarchive(window, pane)
  local registry = load_registry()
  local choices = {}

  for _, workspace in ipairs(list_workspaces(registry, 'archived')) do
    table.insert(choices, {
      id = workspace.name,
      label = workspace_choice_label(workspace),
    })
  end

  if #choices == 0 then
    notify(window, 'Aucun workspace archive.')
    return
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = 'Desarchiver un workspace',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(win, _, id, label)
        local name = id or label

        if not name then
          return
        end

        local ok, done = pcall(function()
          return set_workspace_archived(name, false)
        end)

        if ok and done then
          append_debug('unarchive workspace name=' .. tostring(name))
          notify(win, 'Workspace desarchive: ' .. name)
        else
          append_debug('unarchive failed name=' .. tostring(name) .. ' err=' .. tostring(done))
          notify_error(win, 'Impossible de desarchiver: ' .. name)
        end
      end),
    },
    pane
  )
end

function M.activate_relative(window, pane, offset)
  local registry = load_registry()
  local workspaces = list_workspaces(registry, 'active')

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

-- Restaure TOUS les workspaces actifs (non archives), chacun dans sa fenetre.
-- Usage typique : apres un redemarrage d'un mux-server (vibe, ou le mux local
-- apres un reboot), quand les panes vivants sont morts avec lui. Les workspaces
-- deja vivants sont ignores (pas de doublon), ceux sans snapshot de tabs aussi.
--
-- Le decompte distingue ces deux raisons de saut : « 0/3 » tout court ne disait
-- pas si les workspaces etaient deja ouverts ou depourvus de snapshot.
function M.restore_all_active(window, pane)
  local workspaces = list_workspaces(load_registry(), 'active')

  if #workspaces == 0 then
    notify(window, 'Aucun workspace actif a restaurer.')
    return
  end

  local restored, live, empty, unreachable = 0, 0, 0, 0

  for _, workspace in ipairs(workspaces) do
    if type(workspace.tabs) ~= 'table' or #workspace.tabs == 0 then
      append_debug('restore all skip (aucun snapshot) name=' .. tostring(workspace.name))
      empty = empty + 1
    elseif workspace_is_live(workspace.name) then
      append_debug('restore all skip (deja vivant) name=' .. tostring(workspace.name))
      live = live + 1
    elseif not domains.ensure_attached(workspace.domain) then
      -- Serveur eteint ou VPN coupe : les workspaces locaux doivent quand meme
      -- se restaurer, donc on saute l'entree au lieu d'interrompre la boucle.
      append_debug('restore all skip (domaine injoignable) name=' .. tostring(workspace.name)
        .. ' domain=' .. tostring(workspace.domain))
      unreachable = unreachable + 1
    else
      restore_workspace(window, pane, workspace)
      restored = restored + 1
    end
  end

  local details = {}

  if live > 0 then
    table.insert(details, live .. ' deja ouverts')
  end

  if empty > 0 then
    table.insert(details, empty .. ' sans snapshot')
  end

  if unreachable > 0 then
    table.insert(details, unreachable .. ' domaine injoignable')
  end

  local message = 'Workspaces restaures: ' .. restored .. '/' .. #workspaces

  if #details > 0 then
    message = message .. ' (' .. table.concat(details, ', ') .. ')'
  end

  notify(window, message)
end

-- Demarre la boucle d'auto-sauvegarde (une seule fois par process, meme apres un
-- reload de config, grace au drapeau GLOBAL).
-- Branche l'auto-sauvegarde et le prechargement sur `update-status`.
--
-- POURQUOI UN EVENEMENT : un `wezterm.time.call_after` pose pendant
-- l'EVALUATION DU FICHIER DE CONFIG ne se declenche JAMAIS. C'est ce que faisait
-- l'ancienne version — et son drapeau `workspace_auto_save_started` figeait la
-- panne pour de bon. Mesure le 2026-08-18 : GUI demarre depuis 9 min, registre
-- jamais reecrit, zero ligne `enregistre` au journal. Ne JAMAIS rearmer depuis
-- le scope du fichier de config.
--
-- `update-status` est l'evenement dont on est sur qu'il tire, des le premier
-- rendu et sans rien pour l'inhiber.
local HANDLERS_VERSION = 1

function M.start_auto_save()
  -- UNIQUEMENT dans le process GUI. Le wezterm-mux-server local lit ce meme
  -- fichier de config : sans ce garde-fou il tiendrait sa propre boucle sur le
  -- meme registre, avec une vision partielle. `wezterm.gui` n'existe que cote
  -- GUI (meme test que lua/options.lua pour le theme).
  if not wezterm.gui then
    return
  end

  -- Un `wezterm.on` par rechargement de config EMPILERAIT les handlers (meme
  -- garde-fou que le theme dans lua/options.lua) : on n'enregistre qu'une fois
  -- par process.
  if wezterm.GLOBAL.workspace_handlers_version == HANDLERS_VERSION then
    return
  end

  wezterm.GLOBAL.workspace_handlers_version = HANDLERS_VERSION

  wezterm.on('update-status', function()
    arm_auto_save()
    run_preload_once()
  end)
end

return M
