local wezterm = require 'wezterm'
local env = require 'lua/env'
local notify = require 'lua/notify'

local M = {}

-- Domaine local INTEGRE a WezTerm : les panes tournent dans le process
-- wezterm-gui, donc ils meurent avec la fenetre. Il n'est plus propose dans le
-- selecteur (cf. M.LOCAL_MUX) mais reste indispensable comme repli : c'est le
-- seul domaine qui ne peut jamais etre injoignable. Les anciens snapshots de
-- `workspaces.json` portent encore ce nom, ils restent restaurables.
M.LOCAL = 'local'
-- Domaine mux LOCAL : les panes de ce PC tournent dans un wezterm-mux-server
-- (domaine unix, socket local), pas dans le GUI, donc ils survivent a la fermeture
-- ou au crash de la fenetre. C'est le domaine par defaut (cf. M.apply).
M.LOCAL_MUX = 'localmux'
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

-- Delais de la sequence de demarrage (secondes). Le rattachement d'un domaine
-- mux est asynchrone : ni les fenetres reflechies par le serveur au demarrage,
-- ni celles d'une session distante n'apparaissent immediatement. Les deux
-- boucles d'attente sont bornees, et le cas « rien n'est venu » est traite.
local startup_window_retry = 0.1
local startup_window_attempts = 15
local attach_retry = 0.1
local attach_attempts = 15
local attach_attempts_remote = 50

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

-- Script d'integration shell des panes locaux : c'est lui qui emet OSC 7, donc
-- ce qui permet a un split ou un nouvel onglet d'heriter du repertoire courant
-- (cf. shell/wezterm.ps1). Versionne dans le repo, a cote de la config.
local function shell_integration_path()
  return wezterm.config_dir .. '\\shell\\wezterm.ps1'
end

-- argv complet des panes LOCAUX : shell resolu + chargement de l'integration
-- OSC 7, suivi d'une commande optionnelle a rejouer (restore de workspace).
-- Retourne nil hors Windows : `-NoExit -Command` est une syntaxe PowerShell, on
-- laisse alors WezTerm lancer le shell de login.
function M.local_prog(command)
  local shell = M.local_shell_prog()

  if not shell or not M.is_windows() then
    return nil
  end

  local script = ". '" .. shell_integration_path() .. "'"

  if type(command) == 'string' and command ~= '' then
    script = script .. '; ' .. command
  end

  return { shell, '-NoExit', '-Command', script }
end

-- Nom de domaine exploitable, ou nil (vide, absent, overlay).
function M.normalize(name)
  if type(name) ~= 'string' or name == '' or overlay_domains[name] then
    return nil
  end

  return name
end

-- « Tourne sur CE PC » : le domaine integre ET le mux local. La distinction
-- porte sur la MACHINE, pas sur la persistance : c'est elle qui decide quel
-- shell rejouer a la restauration (cf. lua/workspaces.lua) et comment colorer la
-- barre de statut.
function M.is_local(name)
  name = M.normalize(name)
  return name == M.LOCAL or name == M.LOCAL_MUX
end

function M.is_remote(name)
  name = M.normalize(name)
  return name ~= nil and not M.is_local(name)
end

-- Porte de sortie : `WEZTERM_LOCAL_MUX=0` dans l'environnement fait demarrer
-- WezTerm sur le domaine integre. Indispensable parce que le domaine par defaut
-- est rattache AVANT tout : s'il est injoignable, WezTerm ne s'ouvre pas du tout
-- (« failed to connect to Socket(...); terminating » dans
-- ~/.local/share/wezterm/wezterm-gui.exe-log-*.txt). Un `--config
-- default_domain=...` en ligne de commande ne sert a rien, `M.apply` le reecrit.
function M.local_mux_enabled()
  local value = os.getenv('WEZTERM_LOCAL_MUX')

  return value ~= '0' and value ~= 'false'
end

-- Domaine tel qu'il doit etre ENREGISTRE dans workspaces.json. Le domaine
-- integre ne persiste rien : un workspace capture dessus (session de repli,
-- ancienne entree) doit se restaurer dans le mux local, sinon il repartirait
-- eternellement sans persistance. `pane_domain` reste, lui, fidele a la realite
-- du pane — ne pas confondre les deux usages.
function M.persisted(name)
  name = M.normalize(name)

  if name == M.LOCAL then
    return M.LOCAL_MUX
  end

  return name
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

-- Rattache le domaine si besoin. Indispensable avant tout spawn sur un domaine
-- mux, local comme distant : detache, il refuse le spawn. Seul le domaine
-- integre est toujours pret. Pour le mux local, attach() demarre le serveur au
-- besoin. Retourne ok, message d'erreur.
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

  return M.LOCAL_MUX
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

-- Le domaine integre `local` n'est PAS propose : tout ce qui tourne sur ce PC
-- passe par le mux local, sinon rien ne survit a la fermeture de la fenetre.
-- Il reste joignable comme repli automatique (cf. gui-startup).
local function domain_choices()
  return {
    { id = M.LOCAL_MUX, label = 'Local - ce PC (panes persistants)' },
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
-- courante. Sert a detecter ce que domain:attach() a reellement rattache.
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

-- Apres rattachement d'un domaine mux (local ou distant), trois cas :
--   - une session y etait vivante : attach l'a reflechie en fenetres locales,
--     on s'y pose ;
--   - rien de reflechi mais la fenetre courante tourne deja sur ce domaine
--     (cas normal du mux local) : il n'y a rien a adopter ;
--   - rien de vivant : on demarre une session sur le domaine vise.
-- attach() etant asynchrone, on laisse un court delai aux fenetres reflechies
-- avant de conclure.
--
-- AUCUNE fenetre n'est fermee ici : depuis que le mux local est le domaine par
-- defaut, la fenetre d'ou part le selecteur est une session VIVANTE. L'ancienne
-- fermeture automatique (« fenetre d'amorcage ») tuerait de vrais panes.
local function adopt_domain_session(window, pane, domain_name, attempts)
  attempts = attempts or 0
  local reflected = windows_on_domain(domain_name, mux_window_id(window))

  if #reflected > 0 then
    focus_mux_window(reflected[1])
    return
  end

  local current_ok, current_pane = pcall(function()
    return window:active_pane()
  end)

  if current_ok and current_pane and M.pane_domain(current_pane) == domain_name then
    notify.info(window, 'Session ' .. M.label(domain_name) .. ' active')
    return
  end

  -- Budget d'attente selon la MACHINE : rattacher le mux local est immediat,
  -- rattacher vibe passe par une poignee de main TLS sur le reseau. Conclure
  -- « aucune session vivante » trop tot ferait ouvrir un workspace `vibe` neuf
  -- alors que la session existe — elle apparaitrait juste apres, en doublon.
  local budget = M.is_remote(domain_name) and attach_attempts_remote or attach_attempts

  if attempts < budget and wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(attach_retry, function()
      adopt_domain_session(window, pane, domain_name, attempts + 1)
    end)
    return
  end

  -- Mux LOCAL sans session : on ouvre une fenetre dedans, sans creer de
  -- workspace nomme d'apres le domaine (contrairement au distant ci-dessous) —
  -- sur ce PC, un demarrage a vide doit rester le workspace courant,
  -- typiquement 'default'.
  if M.is_local(domain_name) then
    local spawned = pcall(function()
      wezterm.mux.spawn_window { domain = M.spawn_domain(domain_name) }
    end)

    if spawned then
      notify.info(window, 'Session locale persistante demarree')
      return
    end
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
-- Les deux cibles sont des domaines mux : meme traitement, y compris pour le mux
-- local (rattachement puis reprise de la session vivante s'il y en a une).
function M.prompt_target(window, pane)
  M.choose(window, pane, 'Ou travailler ?', function(win, p, name)
    local ok, err = M.ensure_attached(name)

    if not ok then
      notify.error(win, 'Connexion a ' .. M.label(name) .. ' impossible ('
        .. tostring(err) .. '), session courante conservee')
      return
    end

    M.set_window_default(win, name)
    adopt_domain_session(win, p, name, 0)
  end)
end

-- NE PAS ajouter de handler `mux-startup` en esperant supprimer la fenetre que
-- le mux-server spawne a son demarrage : verifie sous Windows, l'evenement se
-- declenche bien (avec 0 fenetre a cet instant) mais le spawn par defaut a lieu
-- ensuite quand meme — contrairement a `gui-startup`, il n'est pas inhibe par la
-- presence d'un handler. Cette fenetre est celle que le GUI adopte au demarrage.

-- Aucune fenetre n'est creee ici dans le cas normal : `default_domain` etant le
-- mux local, WezTerm rattache le serveur de lui-meme au demarrage et reflechit
-- ses fenetres vivantes. Toute fenetre spawnee ici ferait DOUBLON — elle
-- s'ouvrait puis se refermait sous les yeux de l'utilisateur, et quand elle
-- partait dans le mux elle y restait (4 fenetres au 4e demarrage).
--
-- Le rattachement etant asynchrone, on verifie apres coup qu'une fenetre est
-- bien apparue, et on en ouvre une dans le mux si ce n'est pas le cas (mux
-- joignable mais sans aucune fenetre : session precedente entierement fermee).
-- Repli ultime sur le domaine integre pour ne jamais rester sans fenetre.
--
-- Ce filet ne couvre PAS le mux injoignable : WezTerm se connecte au domaine par
-- defaut avant tout et se termine si ca echoue, aucun timer Lua ne s'execute
-- alors (cf. `M.local_mux_enabled`).
local function ensure_session_window(attempts)
  attempts = attempts or 0

  local ok, windows = pcall(function()
    return wezterm.gui.gui_windows()
  end)

  if ok and type(windows) == 'table' and #windows > 0 then
    wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = true
    return
  end

  if attempts < startup_window_attempts and wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(startup_window_retry, function()
      ensure_session_window(attempts + 1)
    end)
    return
  end

  for _, name in ipairs { M.LOCAL_MUX, M.LOCAL } do
    local spawned = pcall(function()
      wezterm.mux.spawn_window { domain = M.spawn_domain(name) }
    end)

    if spawned then
      wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = true
      return
    end
  end

  wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = true
end

wezterm.on('gui-startup', function(cmd)
  if cmd then
    -- Lancement explicite (`wezterm start -- prog`, `wezterm connect ...`) :
    -- on respecte la demande sans poser de question.
    pcall(function()
      wezterm.mux.spawn_window(cmd)
    end)
    return
  end

  -- Le selecteur n'est arme qu'une fois la fenetre de session la : pose dans une
  -- fenetre transitoire, il disparaitrait avec elle.
  wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = false

  if wezterm.time and wezterm.time.call_after then
    ensure_session_window(0)
  else
    wezterm.GLOBAL[STARTUP_PROMPT_FLAG] = true
  end
end)

-- Le selecteur exige une GuiWindow, qui n'existe pas encore au moment de
-- `gui-startup` : c'est `update-status` qui l'apporte, des le premier rendu.
-- Le drapeau one-shot evite tout double affichage (et un reload de config ne doit
-- pas reposer la question).
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

  -- Mux LOCAL : les panes de ce PC tournent dans un wezterm-mux-server au lieu
  -- du process GUI, donc ils survivent a la fermeture (ou au crash) de la
  -- fenetre — la reprise redevient un vrai rattachement, pas un rejeu de
  -- snapshot. Le transport est un socket (`~/.local/share/wezterm/sock`) ;
  -- `socket_path` n'a pas besoin d'etre configure, et WezTerm demarre le serveur
  -- a la demande (`wezterm-mux-server --daemonize`).
  --
  -- Le serveur tourne sur CETTE machine et lit DONC CE MEME fichier de config :
  -- il herite de `default_prog` ci-dessous, integration OSC 7 comprise. En
  -- contrepartie il fige la config a son demarrage : modifier `default_prog`
  -- suppose de le redemarrer (les panes deja vivants gardent leur shell).
  --
  -- Limite : le serveur meurt avec la SESSION Windows. La persistance couvre le
  -- GUI, pas la deconnexion ni le reboot.
  config.unix_domains = {
    { name = M.LOCAL_MUX },
  }

  -- Defaut = mux local, et PAS de default_gui_startup_args : le rattachement a
  -- vibe passe par le selecteur de demarrage (gui-startup ci-dessus) ou par
  -- ALT+SHIFT+D, jamais automatiquement.
  --
  -- ATTENTION : WezTerm rattache ce domaine au demarrage et se TERMINE s'il n'y
  -- arrive pas. C'est acceptable pour le mux local (demarre a la demande, sur
  -- cette machine) mais ne le serait pas pour vibe. D'ou `local_mux_enabled` :
  -- le seul moyen de rouvrir WezTerm si le mux local est casse.
  config.default_domain = M.local_mux_enabled() and M.LOCAL_MUX or M.LOCAL

  -- Shell des panes LOCAUX. Sous Windows, le defaut WezTerm est cmd.exe : on
  -- lance PowerShell directement, comme sur vibe, en chargeant l'integration
  -- OSC 7 (sans elle, un split repart du HOME).
  --
  -- ATTENTION : `default_prog` ne vaut que pour ce qui est lance depuis CETTE
  -- machine (domaine integre et mux local, qui partagent ce fichier). Ce que le
  -- mux-server distant lance depend du `default_prog` de son propre
  -- ~/.wezterm.lua, hors de ce repo (cf. VIBE_TLS_SETUP.md).
  local local_prog = M.local_prog()

  if local_prog then
    config.default_prog = local_prog
  end
end

return M
