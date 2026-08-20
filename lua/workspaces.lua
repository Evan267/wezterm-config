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
-- Workspace de PASSAGE de WezTerm : celui qu'on obtient sans rien demander. Ce
-- n'est pas un workspace de travail, il n'est donc jamais enregistre.
local scratch_workspace = 'default'

-- Workspace de PARKING : n'est jamais l'actif, donc son contenu n'est jamais
-- affiche. Deux usages :
--   - le mux-server y gare la fenetre qu'il ouvre a son demarrage (le handler
--     `mux-startup` est dans lua/domains.lua, avec le reste du savoir sur les
--     mux-servers) ;
--   - toute fenetre de workspace y NAIT avant d'etre renommee vers sa cible
--     (cf. spawn_workspace_window, qui explique pourquoi ce detour est le seul
--     chemin correct).
--
-- Declare AVANT `is_saveable_workspace`, qui s'en sert : un `local` lu plus haut
-- dans le fichier ne serait pas le meme nom, ce serait un global a nil, et le
-- test passerait silencieusement.
local parking_workspace = domains.PARKING

-- Ni le workspace de passage ni le garage ne sont des workspaces de travail :
-- aucun des deux n'a de raison d'entrer dans le registre.
local function is_saveable_workspace(name)
  return type(name) == 'string'
    and name ~= ''
    and name ~= scratch_workspace
    and name ~= parking_workspace
end

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

  return scratch_workspace
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

-- Repertoire courant d'un pane VIVANT, dans le meme ordre de confiance que
-- `capture_pane` : ce que le shell annonce d'abord, le titre ensuite, l'OSC 7
-- relu par WezTerm en dernier.
--
-- Cette fonction manquait alors que deux appelants l'utilisaient : l'erreur
-- « attempt to call a nil value » etait avalee par un pcall, et toute
-- l'expulsion des fenetres intruses ne faisait rien, en silence (2026-08-19).
local function pane_cwd(pane, title)
  return pane_user_var(pane, 'WEZTERM_WORKSPACE_CWD')
    or cwd_from_title(title)
    or current_working_dir(pane)
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

-- REFUS D'ECRASER UN ENREGISTREMENT PAR LE CONTENU D'UN AUTRE WORKSPACE.
--
-- WezTerm peut etiqueter une fenetre avec un workspace qui n'est pas le sien
-- (import au rattachement d'un domaine, spawn place dans le workspace actif).
-- La capture, elle, fait confiance a cette etiquette : elle a donc enregistre
-- deux fois la session `chaud-devant` (localmux) a la place de celle de
-- `modif-order` (vibe), detruisant un enregistrement juste.
--
-- Le domaine est le temoin le plus sur : un workspace enregistre sur `vibe` ne
-- peut pas se mettre a vivre sur `localmux` du jour au lendemain. En cas de
-- desaccord, on garde l'ancien enregistrement et on le dit. Perdre une mise a
-- jour est reparable ; perdre la disposition d'un workspace ne l'est pas.
local function contradicts_saved_domain(name, snapshot)
  local existing = find_workspace(load_registry(), name)

  if not existing then
    return false
  end

  local was = domains.normalize(existing.domain)
  local now = domains.normalize(snapshot.domain)

  return was ~= nil and now ~= nil and was ~= now
end

local function upsert_workspace(name, snapshot)
  if contradicts_saved_domain(name, snapshot) then
    append_debug('capture REFUSEE name=' .. tostring(name)
      .. ' : domaine ' .. tostring(snapshot.domain)
      .. ' contredit l enregistrement, disposition conservee')
    return false
  end
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
  -- ORDRE DE CONFIANCE : ce que le shell ANNONCE (user var du tracker), puis
  -- l'OSC 7 relu par WezTerm, et le TITRE seulement en dernier recours. Le
  -- titre etait teste en 2e position et produisait de faux repertoires : le
  -- 2026-08-19, l'onglet 2 de `chaud-devant` a ete enregistre avec
  -- `C:/Program Files/PowerShell/7/pwsh.exe` comme repertoire, extrait du titre
  -- « Administrator: ... pwsh.exe ». Un pane restaure repartait donc d'un
  -- EXECUTABLE. Ne pas remonter le titre dans cet ordre.
  local cwd = tracked_cwd or current_working_dir(p) or cwd_from_title(title)
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
-- ---------------------------------------------------------------------------
-- Sauvegarde a l'EVENEMENT, pas au chronometre
--
-- L'ancienne boucle capturait TOUS les workspaces vivants toutes les 60 s. Deux
-- defauts, mesures le 2026-08-19 :
--   - elle lisait le repertoire de chaque pane, donc un aller-retour reseau
--     synchrone par pane distant, sur le thread GUI ;
--   - elle enregistrait a l'aveugle, y compris un workspace momentanement
--     pollue par une fenetre etrangere — c'est ainsi que la disposition de
--     `modif-order` a ete detruite deux fois.
--
-- Desormais on n'enregistre QUE le workspace qu'on vient de modifier, et
-- seulement quand quelque chose a change : split, nouvel onglet, renommage,
-- ouverture d'un workspace, changement de repertoire annonce par le shell.
--
-- Debounce : une action en declenche souvent plusieurs (un split emet aussi un
-- changement de cwd). On coalesce, et on laisse le temps au nouveau pane
-- d'exister avant de le capturer.
-- Deux cadences : les actions discretes (un split, un onglet) sont capturees
-- vite ; un redimensionnement, lui, arrive en rafale et doit d'abord se calmer.
local save_debounce = 2
local resize_debounce = 5

-- ANTI-REBOND DE FIN. Chaque demande annule la precedente : la capture part N
-- secondes apres la DERNIERE, pas apres la premiere. C'est ce qui permet de
-- brancher un redimensionnement — maintenir une touche ou trainer le bord d'une
-- fenetre emet des dizaines d'evenements, et il n'en resultera qu'une seule
-- capture, une fois le geste fini.
--
-- Le jeton est un simple compteur par workspace : la fonction differee ne fait
-- rien si un jeton plus recent a ete emis entre-temps.
local save_tokens = {}

local function capture_workspace_now(name)
  if not is_saveable_workspace(name) then
    return
  end

  for _, mux_window in ipairs(workspace_mux_windows(name)) do
    local captured, snapshot = pcall(capture_mux_window, mux_window, nil)

    if not captured then
      append_debug('capture erreur name=' .. tostring(name) .. ': ' .. tostring(snapshot))
    elseif snapshot_has_content(snapshot) then
      pcall(upsert_workspace, name, snapshot)
      return
    end
  end
end

-- Point d'entree unique : « ce workspace a bouge, enregistre-le bientot ».
local function save_soon(name, delay)
  name = canonical_workspace_name(name)

  if not is_saveable_workspace(name) then
    return
  end

  if not (wezterm.time and wezterm.time.call_after) then
    return
  end

  local token = (save_tokens[name] or 0) + 1
  save_tokens[name] = token

  wezterm.time.call_after(delay or save_debounce, function()
    -- Une demande plus recente est arrivee : celle-ci n'a plus lieu d'etre.
    if save_tokens[name] ~= token then
      return
    end

    save_tokens[name] = nil

    local ok, err = pcall(capture_workspace_now, name)

    if not ok then
      append_debug('sauvegarde erreur name=' .. tostring(name) .. ': ' .. tostring(err))
    end
  end)
end

-- Enregistre le workspace de la fenetre courante. Exportee : les raccourcis de
-- lua/keys.lua s'en servent pour signaler ce que WezTerm n'expose pas en
-- evenement (fermeture d'un pane ou d'un onglet, redimensionnement au clavier).
local function save_window_soon(window, delay)
  local ok, name = pcall(function()
    return window:active_workspace()
  end)

  if ok and name then
    save_soon(name, delay)
  end
end

function M.note_change(window, delay)
  save_window_soon(window, delay)
end

function M.note_resize(window)
  save_window_soon(window, resize_debounce)
end

-- Le redimensionnement de la FENETRE change la taille de tous ses panes. Seul
-- evenement de geometrie expose par WezTerm (pas de `pane-resized`), et il part
-- en rafale pendant un glisser : l'anti-rebond de fin s'en charge.
wezterm.on('window-resized', function(window)
  save_window_soon(window, resize_debounce)
end)
-- ---------------------------------------------------------------------------
-- AMORCAGE : demarrer, puis rattacher — jamais sous une frappe
--
-- Les domaines dont les workspaces ACTIFS ont besoin sont prepares au lancement,
-- pour que leurs sessions soient deja la au moment d'y basculer. En deux temps,
-- et l'ordre compte :
--
--   t+0   le mux local est DEMARRE, en tache de fond, si un workspace actif y
--         vit. C'est la seule operation vraiment couteuse de la chaine (creation
--         de process, lecture de config, shell) et la seule qu'on ne peut pas
--         raccourcir : on la lance donc au plus tot, sans rien attendre.
--   t+2s  les domaines sont RATTACHES. Rattacher est synchrone sur le thread
--         GUI, mais c'est bon marche face a un serveur qui tourne deja — tout
--         le cout venait de son demarrage, que les 2 s ont couvert.
--
-- Ne pas confondre les deux : c'est en les melangeant (rattacher un serveur
-- eteint, donc le demarrer au passage) qu'on gelait 4,4 s d'interface, et sous
-- la frappe qui ouvrait le workspace plutot qu'au lancement.
local preload_flag = 'workspace_preload_done'
local preload_delay = 2

-- Domaines effectivement utilises par les workspaces actifs, sans doublon.
local function active_domains()
  local seen, ordered = {}, {}

  for _, workspace in ipairs(list_workspaces(load_registry(), 'active')) do
    local domain = domains.normalize(workspace.domain)

    if domain and not seen[domain] then
      seen[domain] = true
      table.insert(ordered, domain)
    end
  end

  return ordered
end

local function preload_domains(wanted)
  for _, domain in ipairs(wanted) do
    local ok, reason = domains.preload(domain)
    append_debug('prechargement domaine=' .. domain
      .. ' ok=' .. tostring(ok) .. ' (' .. tostring(reason) .. ')')
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

  local wanted = active_domains()

  for _, domain in ipairs(wanted) do
    if domains.is_local(domain) then
      domains.start_local_mux()
      break
    end
  end

  wezterm.time.call_after(preload_delay, function()
    local ok, err = pcall(preload_domains, wanted)

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


-- Duree pendant laquelle une reconstruction est consideree « en vol ». La
-- construction est synchrone, mais elle rend la main a chaque spawn (fenetre,
-- onglet, split) : une deuxieme entree sur le meme workspace peut donc s'y
-- glisser, et elle en reconstruirait un second jeu complet.
local BUILD_FLIGHT_SECONDS = 10

local function build_flight_key(name)
  return 'workspace_build_in_flight_' .. tostring(name)
end

local function build_in_flight(name)
  local deadline = wezterm.GLOBAL[build_flight_key(name)]

  return type(deadline) == 'number' and os.time() < deadline
end

-- `mux_window` est celle que l'appelant vient de creer COTE MUX : ne jamais la
-- redemander a `window:mux_window()`. L'objet GuiWindow passe au callback d'un
-- raccourci reste lie a la fenetre mux qu'il avait au moment de la frappe, donc
-- a l'ANCIEN workspace — indefiniment, tant que cette fenetre vit encore
-- ailleurs dans le mux.
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

-- ---------------------------------------------------------------------------
-- CREATION DE LA FENETRE D'UN WORKSPACE
--
-- C'est le SEUL endroit du depot qui cree la fenetre d'un workspace, et il
-- n'utilise PAS `SwitchToWorkspace { spawn = ... }`. Ce spawn-la ne met pas la
-- fenetre dans le workspace demande : WezTerm la cree dans
-- `mux.active_workspace()` (wezterm-gui/src/spawn.rs), et `ClientDomain::spawn`
-- envoie cette meme valeur au mux-server (wezterm-client/src/domain.rs). Or
-- l'actif n'est pas forcement la cible : `reconcile_workspace`
-- (wezterm-gui/src/frontend.rs) voit que le workspace qu'on vient d'activer est
-- encore VIDE et bascule d'autorite sur le premier workspace non vide qu'il
-- trouve — `default`. Le garde-fou cense l'en empecher
-- (`switching_workspaces`) est un booleen UNIQUE du front-end : deux bascules en
-- vol (ALT+SHIFT+R en enchaine trois) et la premiere qui aboutit l'efface pour
-- les suivantes.
--
-- Mesure le 2026-08-20 sur `chaud-devant` (localmux) : deux fenetres etiquetees
-- `default` cote serveur (`wezterm cli list`), portant le cwd du workspace
-- demande, et aucune fenetre dans `chaud-devant` ou poser la disposition. Elles
-- SURVIVENT au GUI : chaque rattachement suivant les reimporte, d'ou la volee de
-- fenetres parasites. Le mux local en est la victime designee — son serveur
-- demarre pendant la restauration, et la fenetre qu'il ouvre alors est
-- justement le « workspace non vide » sur lequel `reconcile_workspace` se
-- rabat.
--
-- CE QU'ON FAIT A LA PLACE : creer la fenetre nous-memes cote mux, dans le
-- workspace de PARKING, puis la RENOMMER vers sa cible.
--
-- Le renommage n'est pas cosmetique, c'est lui qui corrige le SERVEUR :
-- `set_workspace` emet `WindowWorkspaceChanged`, que le client traduit en
-- `SetWindowWorkspace` pour le mux-server. Passer directement
-- `workspace = <cible>` au spawn ne corrigerait que le cote client — c'est le
-- piege de 8a40e21, ou le serveur gardait l'etiquette du workspace actif et
-- ressortait les panes dans le workspace courant au rattachement suivant. La
-- fenetre doit donc NAITRE AILLEURS que dans sa cible pour qu'il y ait un
-- renommage a notifier : `set_workspace` ne notifie rien quand le nom ne change
-- pas. Le parking n'etant jamais l'actif, elle n'apparait a l'ecran a aucun
-- moment de ce detour.
--
-- La bascule qui suit n'a alors plus rien a spawner : elle rejoint une fenetre
-- qui existe deja, donc plus d'aller-retour asynchrone ou l'actif puisse
-- deriver.
-- ---------------------------------------------------------------------------
local function spawn_workspace_window(name, spawn)
  local options = merge_spawn_options({ workspace = parking_workspace }, spawn)

  local ok, spawned_tab, spawned_pane, mux_window = pcall(function()
    return wezterm.mux.spawn_window(options)
  end)

  if not ok or not mux_window then
    append_debug('spawn_window echec name=' .. tostring(name)
      .. ' err=' .. tostring(spawned_tab))
    return nil
  end

  local renamed, err = pcall(function()
    mux_window:set_workspace(name)
  end)

  if not renamed then
    append_debug('set_workspace echec name=' .. tostring(name) .. ' err=' .. tostring(err))
    return nil
  end

  append_debug('fenetre creee name=' .. tostring(name))

  return mux_window, spawned_pane
end

-- Construit la fenetre du workspace, y pose la disposition, puis bascule dessus.
-- `wezterm.mux.spawn_window` rend fenetre, onglet et pane immediatement : il n'y
-- a plus rien a attendre ensuite — ni fenetre d'accueil a guetter, ni
-- disposition posee en differe.
local function restore_workspace_in_current_window(window, pane, workspace)
  wezterm.GLOBAL[build_flight_key(workspace.name)] = os.time() + BUILD_FLIGHT_SECONDS

  local mux_window = spawn_workspace_window(
    workspace.name,
    merge_spawn_options(
      workspace_domain_spawn(workspace),
      first_layout_spawn(workspace, 1, build_tab_layout(workspace.tabs[1]))
    )
  )

  if not mux_window then
    wezterm.GLOBAL[build_flight_key(workspace.name)] = nil
    notify_error(window, 'Impossible d ouvrir le workspace: ' .. workspace.name)
    return false
  end

  restore_layout_in_window(window, mux_window, workspace)
  wezterm.GLOBAL[build_flight_key(workspace.name)] = nil

  window:perform_action(
    wezterm.action.SwitchToWorkspace { name = workspace.name },
    pane
  )

  save_soon(workspace.name)

  return true
end

-- Rythme d'attente du domaine (cf. `restore_workspace`). Six essais couvrent
-- largement le demarrage d'un mux-server ; au-dela, le probleme n'est pas une
-- question de patience.
local ATTACH_RETRY_DELAY = 1.2
local ATTACH_MAX_RETRIES = 6

local function restore_workspace(window, pane, workspace, attempt)
  attempt = attempt or 0

  if attempt == 0 then
    append_debug('restore start name=' .. tostring(workspace.name)
      .. ' domain=' .. tostring(workspace.domain))
  end

  -- Reconstruction deja en vol : on la laisse finir, elle bascule elle-meme a la
  -- fin. En relancer une par-dessus creerait un deuxieme jeu de fenetres, et
  -- basculer tout de suite serait pire : la fenetre cible n'existe pas encore,
  -- donc WezTerm en spawnerait une de son cru, sur le domaine de son choix.
  if build_in_flight(workspace.name) then
    append_debug('restore deja en vol, on laisse finir name=' .. tostring(workspace.name))
    return
  end

  -- Un domaine mux detache refuse tout spawn : il doit etre rattache AVANT de
  -- restaurer, sinon le workspace s'ouvre vide. Mais rattacher est SYNCHRONE sur
  -- le thread GUI : le faire ici, sous la frappe, c'est geler le terminal le
  -- temps que le serveur reponde — et s'il n'est pas demarre, le temps qu'il
  -- naisse. Mesure du 2026-08-20 : 4,4 s d'interface morte a la premiere
  -- ouverture d'un workspace local.
  --
  -- On ne rattache donc jamais ici. Si le domaine n'est pas pret, on le prepare
  -- et on repasse : le GUI reste vivant, l'utilisateur voit un message au lieu
  -- d'un terminal fige, et le rattachement se fait en differe (`domains.preload`
  -- sonde le distant avant de s'y connecter, et le mux local a ete demarre entre
  -- temps). L'attente est bornee.
  if not domains.is_attached(workspace.domain) then
    if attempt >= ATTACH_MAX_RETRIES then
      append_debug('restore attach abandon name=' .. tostring(workspace.name)
        .. ' domain=' .. tostring(workspace.domain))
      notify_error(window, 'Domaine ' .. domains.label(workspace.domain) .. ' injoignable: ' .. workspace.name)
      return
    end

    if attempt == 0 then
      if domains.is_local(workspace.domain) then
        domains.start_local_mux()
      end

      notify(window, 'Domaine ' .. domains.label(workspace.domain) .. ': connexion...')
    end

    wezterm.time.call_after(ATTACH_RETRY_DELAY, function()
      local ok, reason = domains.preload(workspace.domain)

      if not ok then
        append_debug('restore attente domaine=' .. tostring(workspace.domain)
          .. ' (' .. tostring(reason) .. ')')
      end

      -- Le pane d'origine peut avoir disparu entre temps (overlay referme,
      -- bascule) : on repart du pane actif de la fenetre.
      local host_ok, host = pcall(function()
        return window:active_pane()
      end)

      restore_workspace(window, (host_ok and host) or pane, workspace, attempt + 1)
    end)

    return
  end

  -- PAS de mode « nouvelle fenetre ». Invariant du depot : une seule fenetre
  -- ouverte a la fois. Un workspace s'ouvre la ou on est — WezTerm y revele la
  -- fenetre du workspace cible — jamais a cote.
  if workspace_is_live(workspace.name) then
    append_debug('restore live switch name=' .. tostring(workspace.name))

    window:perform_action(wezterm.action.SwitchToWorkspace { name = workspace.name }, pane)
    save_soon(workspace.name)
    notify(window, 'Workspace live rejoint: ' .. workspace.name)
    return
  end

  if type(workspace.tabs) ~= 'table' or #workspace.tabs == 0 then
    append_debug('restore legacy workspace name=' .. tostring(workspace.name))

    if not spawn_workspace_window(workspace.name, workspace_domain_spawn(workspace)) then
      notify_error(window, 'Impossible d ouvrir le workspace: ' .. workspace.name)
      return
    end

    window:perform_action(wezterm.action.SwitchToWorkspace { name = workspace.name }, pane)
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

          -- Meme chemin que la restauration, et pour la meme raison : le spawn
          -- de `SwitchToWorkspace` deposerait la fenetre dans le workspace
          -- ACTIF (cf. spawn_workspace_window).
          if not spawn_workspace_window(line, { domain = domains.spawn_domain(domain) }) then
            notify_error(w, 'Impossible de creer le workspace: ' .. line)
            return
          end

          w:perform_action(wezterm.action.SwitchToWorkspace { name = line }, sel_pane)

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
    return
  end

  save_window_soon(window)
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
    return
  end

  save_window_soon(window)
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
        save_window_soon(win)
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

  local restored, live, empty = 0, 0, 0

  for _, workspace in ipairs(workspaces) do
    if type(workspace.tabs) ~= 'table' or #workspace.tabs == 0 then
      append_debug('restore all skip (aucun snapshot) name=' .. tostring(workspace.name))
      empty = empty + 1
    elseif workspace_is_live(workspace.name) then
      append_debug('restore all skip (deja vivant) name=' .. tostring(workspace.name))
      live = live + 1
    else
      -- Aucun test de domaine ici : c'est `restore_workspace` qui attend le
      -- sien, en differe et sans geler. Sonder les domaines dans cette boucle
      -- revenait a les sonder tous d'affilee, sous la frappe — un
      -- aller-retour reseau par domaine avant la moindre ouverture.
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
-- Auto-sauvegarde, prechargement : branches sur `update-status`, AU NIVEAU DU
-- MODULE, comme lua/notify.lua — et sans garde-fou « une fois par process ».
--
-- WezTerm reconstruit sa table de handlers a chaque evaluation de la config, et
-- il y en a une a chaque rechargement. Un garde-fou dans `wezterm.GLOBAL`, lui,
-- survit aux rechargements : il bloquait donc tout re-enregistrement APRES que
-- WezTerm eut vide la table. Le handler etait enregistre une fois, puis perdu au
-- premier rechargement et jamais repose — l'auto-save et le prechargement ne
-- tournaient plus, sans le moindre message. Constate le 2026-08-19 : la ligne
-- « handlers enregistres » au journal, et aucune trace de declenchement ensuite.
--
-- Re-enregistrer a chaque evaluation est le comportement CORRECT ici, pas une
-- fuite : la table repart vide a chaque fois.
-- PAS de declencheur sur `user-var-changed`. Tentation evidente : le shell
-- annonce son repertoire a chaque invite (cf. shell/wezterm.ps1), ce qui ferait
-- un signal « ce pane a bouge » gratuit. Essaye le 2026-08-19, retire le meme
-- soir : la cadence est imprevisible — une TUI qui redessine, un prompt qui se
-- reaffiche, et l'evenement part en rafale. Chaque rafale relancait une capture
-- toutes les 2 s, donc des allers-retours reseau pour chaque pane distant, sur
-- le thread GUI. WezTerm s'est fige juste apres une restauration pourtant
-- reussie.
--
-- On s'en tient donc aux ACTIONS explicites, dont on maitrise la frequence :
-- split, nouvel onglet, renommage, ouverture d'un workspace. Un `cd` seul n'est
-- pas enregistre tout de suite ; il le sera a la prochaine action ou a la
-- prochaine ouverture du workspace.

wezterm.on('update-status', function()
  -- Uniquement cote GUI. Le wezterm-mux-server local lit ce meme fichier de
  -- config ; sans ce test il tiendrait sa propre boucle de sauvegarde sur le
  -- meme registre, avec une vision partielle.
  if not wezterm.gui then
    return
  end

  run_preload_once()
end)

-- Conservee : `wezterm.lua` l'appelle. Le branchement se fait desormais a
-- l'evaluation du module, cette fonction n'a plus rien a faire.
function M.start_auto_save()
end

return M
