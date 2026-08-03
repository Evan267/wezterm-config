local wezterm = require 'wezterm'
local env = require 'lua/env'
local notify = require 'lua/notify'

local M = {}

-- Domaine local integre a WezTerm : les panes tournent sur CE PC.
M.LOCAL = 'local'
-- Domaine mux TLS de la machine distante (cf. VIBE_TLS_SETUP.md).
M.REMOTE = env.VIBE_DOMAIN

-- Domaines d'overlay (InputSelector, PromptInputLine) : jamais persistes dans
-- workspaces.json ni proposes comme cible. Un pane d'overlay repond
-- 'TermWizTerminalDomain' a get_domain_name(), ce qui polluerait les snapshots.
local overlay_domains = {
  TermWizTerminalDomain = true,
}

-- Drapeau one-shot du selecteur de demarrage. Dans wezterm.GLOBAL pour survivre
-- a un reload de config (qui reconstruit l'etat Lua) : le selecteur ne doit
-- s'afficher qu'au tout premier lancement du process, pas a chaque reload.
local STARTUP_PROMPT_FLAG = 'domain_startup_prompt_pending'

-- Delais de la sequence de demarrage (secondes). Le selecteur a besoin d'une
-- GuiWindow, qui n'existe pas encore quand gui-startup se declenche ; et
-- domain:attach() est asynchrone, les fenetres distantes n'apparaissent pas
-- immediatement.
local gui_ready_retry = 0.1
local gui_ready_attempts = 30
local attach_retry = 0.1
local attach_attempts = 15
local close_bootstrap_delay = 0.4

-- Shell des panes locaux, par ordre de preference sous Windows. pwsh.exe
-- (PowerShell 7+) d'abord, powershell.exe (5.1, toujours present) en repli.
local windows_shells = { 'pwsh.exe', 'powershell.exe' }
local SHELL_PROG_CACHE = 'domain_local_shell_prog'

function M.is_windows()
  return wezterm.target_triple:find('windows') ~= nil
end

local function shell_exists(name)
  local ok, found = pcall(function()
    local success = wezterm.run_child_process { 'where.exe', name }
    return success
  end)

  return ok and found == true
end

-- Shell a lancer dans les panes LOCAUX, ou nil pour laisser WezTerm decider
-- (shell de login sous Unix). Le resultat est mis en cache dans wezterm.GLOBAL :
-- la detection passe par un process enfant, elle ne doit tourner qu'une fois par
-- process, pas a chaque rechargement de config.
function M.local_shell_prog()
  local configured = env.SHELL_PROG

  if type(configured) == 'string' and configured ~= '' then
    return configured
  end

  if not M.is_windows() then
    return nil
  end

  local cached = wezterm.GLOBAL[SHELL_PROG_CACHE]

  if type(cached) == 'string' and cached ~= '' then
    return cached
  end

  for _, candidate in ipairs(windows_shells) do
    if shell_exists(candidate) then
      wezterm.GLOBAL[SHELL_PROG_CACHE] = candidate
      return candidate
    end
  end

  -- Aucune detection concluante : powershell.exe est present sur tout Windows,
  -- c'est un repli plus sur que cmd.exe (le defaut WezTerm).
  wezterm.GLOBAL[SHELL_PROG_CACHE] = windows_shells[#windows_shells]
  return wezterm.GLOBAL[SHELL_PROG_CACHE]
end

-- Nom de domaine exploitable, ou nil (vide, absent, overlay).
function M.normalize(name)
  if type(name) ~= 'string' or name == '' or overlay_domains[name] then
    return nil
  end

  return name
end

function M.is_remote(name)
  name = M.normalize(name)
  return name ~= nil and name ~= M.LOCAL
end

-- Etiquette courte pour les listes et la barre de statut.
function M.label(name)
  return M.normalize(name) or '?'
end

-- Valeur du champ `domain` d'un SpawnCommand. Un nom explicite est TOUJOURS
-- preferable a 'DefaultDomain' : le domaine par defaut varie desormais par
-- fenetre (ALT+SHIFT+D), un workspace doit se restaurer la ou il a ete capture.
function M.spawn_domain(name)
  name = M.normalize(name)

  if name then
    return { DomainName = name }
  end

  return 'DefaultDomain'
end

function M.pane_domain(pane)
  local ok, name = pcall(function()
    return pane:get_domain_name()
  end)

  if not ok then
    return nil
  end

  return M.normalize(name)
end

-- Rattache le domaine si besoin. Indispensable avant tout spawn distant : un
-- domaine mux detache refuse le spawn. Retourne ok, message d'erreur.
function M.ensure_attached(name)
  name = M.normalize(name)

  if not name or name == M.LOCAL then
    return true
  end

  local found, domain = pcall(wezterm.mux.get_domain, name)

  if not found or not domain then
    return false, 'domaine inconnu'
  end

  local state_ok, state = pcall(function()
    return domain:state()
  end)

  if state_ok and state == 'Attached' then
    return true
  end

  local attached, err = pcall(function()
    domain:attach()
  end)

  if not attached then
    return false, tostring(err)
  end

  return true
end

-- Domaine par defaut de la fenetre : l'override pose par ALT+SHIFT+D prime sur
-- le `config.default_domain` global.
function M.window_default(window)
  local ok, overrides = pcall(function()
    return window:get_config_overrides()
  end)

  if ok and type(overrides) == 'table' and M.normalize(overrides.default_domain) then
    return overrides.default_domain
  end

  local config_ok, config = pcall(function()
    return window:effective_config()
  end)

  if config_ok and config and M.normalize(config.default_domain) then
    return config.default_domain
  end

  return M.LOCAL
end

-- Bascule le domaine par defaut d'UNE fenetre. Attention : tout autre
-- set_config_overrides doit reporter `default_domain`, sinon il efface ce choix
-- (cf. lua/options.lua, handler de bascule clair/sombre).
function M.set_window_default(window, name)
  name = M.normalize(name)

  if not name then
    return
  end

  pcall(function()
    local overrides = window:get_config_overrides() or {}
    overrides.default_domain = name
    window:set_config_overrides(overrides)
  end)
end

local function domain_choices()
  return {
    { id = M.LOCAL, label = 'Local - ce PC' },
    { id = M.REMOTE, label = M.REMOTE .. ' - serveur distant (' .. env.VIBE_ADDR .. ')' },
  }
end

-- Selecteur de domaine reutilisable (demarrage, ALT+SHIFT+D, nouveau workspace).
-- `on_choice(window, pane, domain_name)` n'est appele que sur choix effectif.
function M.choose(window, pane, title, on_choice)
  window:perform_action(
    wezterm.action.InputSelector {
      title = title,
      choices = domain_choices(),
      fuzzy = false,
      action = wezterm.action_callback(function(win, p, id, label)
        local name = id or label

        if name then
          on_choice(win, p, name)
        end
      end),
    },
    pane
  )
end

function M.prompt_switch_default(window, pane)
  M.choose(window, pane, 'Domaine par defaut de cette fenetre', function(win, _, name)
    local ok, err = M.ensure_attached(name)

    if not ok then
      notify.error(win, 'Domaine indisponible: ' .. M.label(name) .. ' (' .. tostring(err) .. ')')
      return
    end

    M.set_window_default(win, name)
    notify.info(win, 'Domaine par defaut: ' .. M.label(name))
  end)
end

local function focus_mux_window(mux_window)
  pcall(function()
    local gui_window = mux_window:gui_window()
    gui_window:restore()
    gui_window:focus()
  end)
end

local function mux_window_id(window)
  local ok, id = pcall(function()
    return window:mux_window():window_id()
  end)

  if ok then
    return id
  end

  return nil
end

-- Fenetres mux dont le pane actif tourne sur `domain_name`, hors fenetre
-- d'amorcage. Sert a detecter ce que domain:attach() a reellement rattache.
local function windows_on_domain(domain_name, exclude_id)
  local result = {}

  if not wezterm.mux or not wezterm.mux.all_windows then
    return result
  end

  for _, mux_window in ipairs(wezterm.mux.all_windows()) do
    local id_ok, id = pcall(function()
      return mux_window:window_id()
    end)

    if not id_ok or id ~= exclude_id then
      local pane_ok, pane = pcall(function()
        return mux_window:active_pane()
      end)

      if pane_ok and pane and M.pane_domain(pane) == domain_name then
        table.insert(result, mux_window)
      end
    end
  end

  return result
end

-- Ferme la fenetre d'amorcage locale devenue inutile. Garde-fou : ne jamais
-- fermer la DERNIERE fenetre, WezTerm quitterait l'application.
local function close_bootstrap_window(window)
  wezterm.time.call_after(close_bootstrap_delay, function()
    local ok, gui_windows = pcall(function()
      return wezterm.gui.gui_windows()
    end)

    if not ok or type(gui_windows) ~= 'table' or #gui_windows < 2 then
      return
    end

    pcall(function()
      window:perform_action(wezterm.action.CloseCurrentTab { confirm = false }, window:active_pane())
    end)
  end)
end

-- Apres rattachement du domaine distant, deux cas :
--   - une session distante etait vivante : attach l'a reflechie en fenetres
--     locales, on s'y pose et on ferme la fenetre d'amorcage ;
--   - rien de vivant : la fenetre d'amorcage devient la fenetre distante.
-- attach() etant asynchrone, on laisse un court delai aux fenetres reflechies
-- avant de conclure au second cas.
local function adopt_remote_session(window, pane, domain_name, attempts)
  attempts = attempts or 0
  local reflected = windows_on_domain(domain_name, mux_window_id(window))

  if #reflected > 0 then
    focus_mux_window(reflected[1])
    close_bootstrap_window(window)
    return
  end

  if attempts < attach_attempts and wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(attach_retry, function()
      adopt_remote_session(window, pane, domain_name, attempts + 1)
    end)
    return
  end

  window:perform_action(
    wezterm.action.SwitchToWorkspace {
      name = domain_name,
      spawn = { domain = M.spawn_domain(domain_name) },
    },
    pane
  )

  notify.info(window, 'Session ' .. M.label(domain_name) .. ' demarree')
end

-- Selecteur « ou travailler ? ». Affiche au demarrage, et rejouable a la main.
function M.prompt_target(window, pane)
  M.choose(window, pane, 'Ou travailler ?', function(win, p, name)
    if not M.is_remote(name) then
      M.set_window_default(win, M.LOCAL)
      notify.info(win, 'Session locale (ce PC)')
      return
    end

    local ok, err = M.ensure_attached(name)

    if not ok then
      notify.error(win, 'Connexion a ' .. M.label(name) .. ' impossible ('
        .. tostring(err) .. '), session locale conservee')
      return
    end

    M.set_window_default(win, name)
    adopt_remote_session(win, p, name, 0)
  end)
end

-- gui-startup ne fournit qu'une MuxWindow ; le selecteur exige une GuiWindow,
-- creee un peu plus tard. On reessaie brievement.
local function prompt_startup_when_ready(mux_window, attempts)
  attempts = attempts or 0

  if not wezterm.GLOBAL[STARTUP_PROMPT_FLAG] then
    return
  end

  local ok, gui_window = pcall(function()
    return mux_window:gui_window()
  end)

  if ok and gui_window then
    wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = false
    M.prompt_target(gui_window, gui_window:active_pane())
    return
  end

  if attempts >= gui_ready_attempts then
    return
  end

  wezterm.time.call_after(gui_ready_retry, function()
    prompt_startup_when_ready(mux_window, attempts + 1)
  end)
end

-- Premiere fenetre TOUJOURS locale : l'ouverture de WezTerm ne doit jamais
-- dependre de la joignabilite du serveur (VPN coupe, vibe eteint). Le
-- rattachement distant est un choix explicite, fait dans le selecteur.
wezterm.on('gui-startup', function(cmd)
  if cmd then
    -- Lancement explicite (`wezterm start -- prog`, `wezterm connect ...`) :
    -- on respecte la demande sans poser de question.
    pcall(function()
      wezterm.mux.spawn_window(cmd)
    end)
    return
  end

  local ok, _, _, mux_window = pcall(function()
    return wezterm.mux.spawn_window { domain = M.spawn_domain(M.LOCAL) }
  end)

  wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = true

  if ok and mux_window and wezterm.time and wezterm.time.call_after then
    prompt_startup_when_ready(mux_window, 0)
  end
end)

-- Filet de securite : si la GuiWindow n'a jamais ete prete a temps ci-dessus,
-- update-status finit par fournir une window valide. Le drapeau one-shot evite
-- tout double affichage.
wezterm.on('update-status', function(window, pane)
  if not wezterm.GLOBAL[STARTUP_PROMPT_FLAG] then
    return
  end

  wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = false
  M.prompt_target(window, pane)
end)

function M.apply(config)
  -- 'vibe' = machine distante (cf. .env / VIBE_TLS_SETUP.md) avec un
  -- wezterm-mux-server persistant lance par tache planifiee. Ce repo est la
  -- config du CLIENT uniquement ; le serveur a sa propre config ~/.wezterm.lua.
  --
  -- TLS direct avec certificats explicites. PAS de bootstrap_via_ssh : sur Windows il
  -- ne garde pas le mux-server vivant (process tue a la fermeture de la session SSH).
  -- PKI partagee, generee a la main, hors repo dans ~/.wezterm-tls (ca/client/server).
  local pki = wezterm.home_dir .. '\\.wezterm-tls\\'

  config.tls_clients = {
    {
      name = M.REMOTE,
      -- Cible TLS par IP : le nom court WS871674 ne se resout pas toujours hors interne.
      remote_address = env.VIBE_ADDR .. ':' .. env.VIBE_TLS_PORT,
      pem_cert = pki .. 'client.crt',
      pem_private_key = pki .. 'client.key',
      -- pas de pem_ca (cf. ~/.wezterm.lua serveur) : pem_root_certs suffit comme
      -- trust store pour valider le certificat serveur.
      pem_root_certs = { pki .. 'ca.pem' },
      -- Connexion par IP : le CN ne matche pas le nom, on desactive la verif du
      -- hostname (le chiffrement et l'auth mutuelle par certificat restent actifs).
      accept_invalid_hostnames = true,
    },
  }

  -- Defaut LOCAL, et PAS de default_gui_startup_args : le rattachement a vibe
  -- passe par le selecteur de demarrage (gui-startup ci-dessus) ou par
  -- ALT+SHIFT+D, jamais automatiquement.
  config.default_domain = M.LOCAL

  -- Shell des panes LOCAUX. Sous Windows, le defaut WezTerm est cmd.exe : on
  -- lance PowerShell directement, comme sur vibe.
  --
  -- ATTENTION : `default_prog` ne vaut QUE pour le domaine local. Ce que le
  -- mux-server distant lance depend du `default_prog` de son propre
  -- ~/.wezterm.lua, hors de ce repo (cf. VIBE_TLS_SETUP.md).
  local shell_prog = M.local_shell_prog()

  if shell_prog then
    config.default_prog = { shell_prog }
  end
end

return M
