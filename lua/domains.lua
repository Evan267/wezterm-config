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

-- Choix proposes a la CREATION d'un workspace (et a ALT+SHIFT+D). Le domaine
-- integre `local` n'y figure pas volontairement : c'est celui du demarrage et du
-- workspace de passage, ou les panes meurent avec la fenetre. Un workspace
-- nomme, lui, doit survivre — donc mux local ou vibe, jamais l'integre.
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

-- AUCUN handler `gui-startup` ici, et c'est DELIBERE : sa seule presence inhibe
-- la creation de la fenetre par defaut de WezTerm, qu'il faudrait alors spawner
-- soi-meme. Sans handler, WezTerm ouvre sa fenetre sur `default_domain`, donc
-- sur le domaine integre — panes dans le process GUI, aucun mux-server sollicite.
--
-- Il n'y a pas non plus de selecteur au demarrage. Le choix du serveur est une
-- question de CREATION de workspace (ALT+n), pas de lancement du terminal : on
-- demarre toujours en local, et c'est en creant un workspace qu'on decide s'il
-- vit dans le mux de ce PC ou sur vibe.

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

  -- Defaut = domaine INTEGRE. WezTerm demarre donc sans solliciter le moindre
  -- mux-server : pas de socket a joindre, pas de serveur a lancer, pas de
  -- session a refleter — et donc aucune des facons de rater ce rattachement.
  --
  -- Un domaine mux n'entre en jeu qu'a la CREATION d'un workspace (ALT+n, qui
  -- demande lequel) ou a l'ouverture d'un workspace enregistre, qui porte son
  -- domaine. `unix_domains` n'a pas `connect_automatically` : le mux local n'est
  -- demarre qu'a la demande, au premier spawn qui le vise.
  --
  -- Contrepartie assumee : les panes du workspace de passage `default` vivent
  -- dans le process GUI et meurent avec lui. C'est le prix d'un demarrage qui ne
  -- peut pas echouer — WezTerm se TERMINE au lancement si son domaine par defaut
  -- est injoignable, ce qui etait le risque permanent de `default_domain =
  -- localmux`. Un workspace nomme, lui, est toujours dans un mux.
  config.default_domain = M.LOCAL

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
