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

-- Workspace de PARKING : il n'est jamais l'actif, donc le GUI ne l'affiche
-- jamais, et il n'est jamais enregistre (cf. lua/workspaces.lua). C'est le
-- garage des fenetres que personne n'a demandees : celle qu'un mux-server ouvre
-- a son demarrage (cf. le handler `mux-startup` plus bas), et celle de tout
-- workspace en cours de construction, avant son renommage (cf.
-- `spawn_workspace_window` dans lua/workspaces.lua).
M.PARKING = 'wezterm-amorcage'

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

-- ---------------------------------------------------------------------------
-- Prechargement des connexions
--
-- Sonder AVANT de rattacher, parce que `domain:attach()` est SYNCHRONE sur le
-- thread GUI : quand la cible ne repond pas, il bloque tout WezTerm le temps du
-- timeout TCP — mesure le 2026-08-19 sur vibe, 12 s d'interface entierement
-- gelee. Le probe, lui, a un timeout que NOUS choisissons.
-- ---------------------------------------------------------------------------
local PROBE_TIMEOUT_MS = 800

local function child_ok(argv)
  local ok, success = pcall(function()
    local success = wezterm.run_child_process(argv)
    return success
  end)

  return ok and success == true
end

-- DEMARRAGE DU MUX LOCAL, EN TACHE DE FOND ET LE PLUS TOT POSSIBLE.
--
-- Avant, le prechargement refusait de le demarrer : un mux-server qui demarre
-- ouvre sa propre fenetre, qui atterrissait dans le workspace de passage. Cette
-- fenetre est desormais garee (cf. le handler `mux-startup`), donc l'objection
-- est levee — et la laisser eteinte coutait bien plus cher que ce qu'elle
-- evitait : la premiere ouverture d'un workspace local payait le demarrage du
-- serveur SOUS LA FRAPPE, `domain:attach()` etant synchrone sur le thread GUI.
-- Mesure du 2026-08-20 : 4,4 s d'interface entierement gelee (journal GUI,
-- « Will try spawning the server » a 09:18:06, workspace ouvert a 09:18:09).
--
-- `background_child_process` ne rend PAS la main sur le process fils : rien
-- n'est attendu, le GUI continue de tourner pendant que le serveur naît. C'est
-- toute la difference avec `run_child_process` (utilise pour les sondes, qui
-- doivent, elles, rendre un resultat).
--
-- Exactement la commande que WezTerm lance lui-meme dans ce cas, prise a cote du
-- binaire courant plutot que dans le PATH.
local START_REQUESTED = 'local_mux_start_requested'
local MUX_SERVER_IMAGE = 'wezterm-mux-server.exe'

local function mux_server_path()
  if M.is_windows() then
    return wezterm.executable_dir .. '\\' .. MUX_SERVER_IMAGE
  end

  return wezterm.executable_dir .. '/wezterm-mux-server'
end

-- Un mux-server tourne-t-il DEJA sur cette machine ?
--
-- `tasklist` sort TOUJOURS en succes, y compris quand son filtre ne trouve rien
-- (« INFO: No tasks are running... ») : c'est sa SORTIE qu'il faut lire, jamais
-- son code de retour. Meme ordre de cout que le `where.exe` de `shell_exists`,
-- sans commune mesure avec un `powershell.exe -Command` (~300 ms rien que pour
-- demarrer l'interpreteur) — on est sur le thread GUI, au demarrage.
--
-- FAIL-OPEN : si la detection echoue, on demarre. Un serveur en trop coute un
-- process ; un serveur manquant coute son demarrage SOUS LA FRAPPE.
local function local_mux_running()
  if not M.is_windows() then
    return false
  end

  local ok, success, stdout = pcall(function()
    return wezterm.run_child_process {
      'tasklist.exe', '/FI', 'IMAGENAME eq ' .. MUX_SERVER_IMAGE, '/NH',
    }
  end)

  if not ok or success ~= true or type(stdout) ~= 'string' then
    return false
  end

  return stdout:find(MUX_SERVER_IMAGE, 1, true) ~= nil
end

-- Une seule demande par process GUI, ET seulement si aucun serveur ne tourne.
--
-- CE GARDE-FOU PROTEGE LA PERSISTANCE DU MUX LOCAL, pas seulement la table des
-- process. Un mux-server qui demarre alors que le socket est deja pris ne meurt
-- PAS — ce que pretendait le commentaire precedent : il le REBINDE et depossede
-- son occupant. Mesure du 2026-08-20 : le serveur lance a 11:03:47 (par le GUI
-- relance a 11:03:45) a recree `sock` a 11:03:47.796 ; celui de 09:57:46 est
-- reste vivant avec ses quatre pwsh, injoignable par quiconque.
--
-- Consequence tant qu'on demarrait sans sonder : a chaque lancement, le client
-- tombait sur un serveur NEUF qui ne connaissait aucun workspace — d'ou les
-- `chaud-devant windows=0` au journal, et une reconstruction depuis le snapshot
-- la ou un rattachement etait attendu. Les panes survivaient bien a la fermeture
-- du GUI, mais dans un process que plus personne ne pouvait joindre : la seule
-- raison d'etre du mux local etait annulee, et les shells s'accumulaient (neuf
-- pwsh vivants pour quatre panes affiches, releve a 11:04).
--
-- Le drapeau GLOBAL ne protege QUE d'une double demande dans le meme process ;
-- il ne sait rien d'un serveur laisse par le process PRECEDENT — or le mux local
-- survit a la fermeture du GUI, c'est sa raison d'etre. D'ou la sonde.
--
-- Si le serveur ainsi detecte ne repond finalement pas au socket, `M.preload`
-- retombe sur le demarrage par WezTerm au rattachement : on perd l'anticipation,
-- pas la connexion.
--
-- Retourne true si la demande vient d'etre emise.
function M.start_local_mux()
  if wezterm.GLOBAL[START_REQUESTED] then
    return false
  end

  wezterm.GLOBAL[START_REQUESTED] = true

  if local_mux_running() then
    return false
  end

  local ok, err = pcall(function()
    wezterm.background_child_process { mux_server_path(), '--daemonize' }
  end)

  if not ok then
    wezterm.log_error('demarrage du mux local impossible: ' .. tostring(err))
  end

  return ok
end

-- Poignee de main TCP bornee a PROBE_TIMEOUT_MS, sans TLS : on ne cherche qu'a
-- savoir si le port repond, pas a valider les certificats.
local function remote_reachable()
  return child_ok {
    'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
    "$c = New-Object Net.Sockets.TcpClient; "
      .. "try { if ($c.ConnectAsync('" .. env.VIBE_ADDR .. "', " .. env.VIBE_TLS_PORT
      .. ").Wait(" .. PROBE_TIMEOUT_MS .. ")) { exit 0 } else { exit 1 } } catch { exit 1 } finally { $c.Close() }",
  }
end

-- Rattache le domaine SI c'est raisonnable, sans jamais risquer un gel : le
-- domaine integre n'a rien a rattacher, le distant n'est rattache que s'il
-- repond au probe. Le mux local, lui, a ete demarre par `M.start_local_mux` —
-- c'est la seule chose qui rendait son rattachement couteux.
--
-- SEUL POINT D'ENTREE ADMIS HORS DEMARRAGE : tout ce qui part d'une frappe passe
-- par ici et jamais par `ensure_attached` en direct. Retourne ok, raison.
function M.preload(name, host_window)
  name = M.normalize(name)

  if not name or name == M.LOCAL then
    return true, 'rien a rattacher'
  end

  if M.is_remote(name) and not remote_reachable() then
    return false, 'injoignable (' .. env.VIBE_ADDR .. ':' .. env.VIBE_TLS_PORT .. ')'
  end

  return M.ensure_attached(name, host_window)
end

-- « Ce domaine est-il deja utilisable ? » — lecture d'etat pure, qui ne rattache
-- rien et ne peut donc rien geler. C'est ce qu'on interroge sous une frappe.
function M.is_attached(name)
  name = M.normalize(name)

  if not name or name == M.LOCAL then
    return true
  end

  local found, domain = pcall(wezterm.mux.get_domain, name)

  if not found or not domain then
    return false
  end

  local ok, state = pcall(function()
    return domain:state()
  end)

  return ok and state == 'Attached'
end

-- Rattache le domaine si besoin. Indispensable avant tout spawn sur un domaine
-- mux, local comme distant : detache, il refuse le spawn. Seul le domaine
-- integre est toujours pret. Retourne ok, message d'erreur.
--
-- BLOQUANT : `domain:attach()` est synchrone sur le thread GUI, et il DEMARRE le
-- serveur si besoin. Ne jamais l'appeler depuis un handler de touche — passer
-- par `M.preload`, qui sonde d'abord, et le faire en differe.
-- FENETRE HOTE DE LA PROGRESSION DE CONNEXION.
--
-- `MuxDomain:attach()` accepte un argument que la doc ne mentionne pas : une
-- MuxWindow. Verifie dans la source de la version installee (20240203,
-- `lua-api-crates/mux/src/domain.rs`) :
--
--   methods.add_async_method("attach",
--     |_, this, window: Option<UserDataRef<MuxWindow>>| async move {
--       domain.attach(window.map(|w| w.0)).await
--
-- et cote client (`wezterm-client/src/domain.rs`) ce window_id part tel quel
-- dans `ConnectionUI::with_params(ConnectionUIParams { window_id, .. })`.
--
-- SANS argument, la ConnectionUI s'ouvre DANS SA PROPRE FENETRE : c'est le
-- « wezterm: Connecting... » qui clignote au demarrage. Capture le 2026-08-20
-- par echantillonnage a 100 ms des fenetres de premier plan — classe
-- org.wezfurlong.wezterm, 1550x926, visible 123 ms (11:03:49.748 a
-- 11:03:49.871), pile sur le rattachement du prechargement. AVEC une fenetre,
-- elle s'affiche dedans et aucune fenetre n'apparait.
--
-- La fenetre du prechargement est capturee a t+0 et servie a t+2 s : elle peut
-- avoir disparu entre temps, d'ou la validation avant usage.
local function attach_host(mux_window)
  if mux_window == nil then
    return nil
  end

  local ok = pcall(function()
    return mux_window:window_id()
  end)

  if not ok then
    return nil
  end

  return mux_window
end

function M.ensure_attached(name, host_window)
  name = M.normalize(name)

  if not name or name == M.LOCAL then
    return true
  end

  if M.is_attached(name) then
    return true
  end

  local found, domain = pcall(wezterm.mux.get_domain, name)

  if not found or not domain then
    return false, 'domaine inconnu'
  end

  local host = attach_host(host_window)

  local attached, err = pcall(function()
    if host then
      domain:attach(host)
    else
      domain:attach()
    end
  end)

  -- Repli sans fenetre hote : un clignotement vaut mieux qu'un domaine non
  -- rattache, qui ferait s'ouvrir vide le workspace suivant.
  if not attached and host then
    attached, err = pcall(function()
      domain:attach()
    end)
  end

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

-- LA FENETRE D'AMORCAGE DU MUX-SERVER, GAREE PLUTOT QUE SUBIE.
--
-- `wezterm-mux-server` ouvre une fenetre a son demarrage SI aucun pane ne vit
-- deja dans son domaine par defaut (wezterm-mux-server/src/main.rs). Cette
-- fenetre-la ne demande aucun workspace : elle atterrit dans `default`, et le
-- GUI la reimporte a CHAQUE rattachement. C'est une fenetre parasite de plus a
-- chaque demarrage du mux local, et un « workspace non vide » tout trouve pour
-- le repli de `reconcile_workspace` (cf. `spawn_workspace_window` dans
-- lua/workspaces.lua, qui detaille les degats).
--
-- On ne peut pas empecher cette fenetre — le serveur veut un pane — mais on
-- peut la CHOISIR : creer nous-memes ce premier pane, dans le workspace de
-- parking, suffit a ce que le serveur n'en cree pas d'autre. Elle existe donc
-- toujours, mais dans un workspace que le client n'affiche jamais.
--
-- Une tentative precedente balayait les fenetres importees pour les deloger
-- apres coup, toutes les 0,5 s, en lisant le repertoire de chaque pane : elle a
-- fige le GUI (cf. e5060dc). Ici il n'y a ni balayage, ni timer, ni lecture de
-- pane — une seule creation, au demarrage du serveur.
--
-- `mux-startup` n'est emis QUE par wezterm-mux-server : cote GUI ce handler ne
-- se declenche jamais. Il est enregistre a l'evaluation du module, comme les
-- autres handlers du depot (cf. lua/workspaces.lua) : WezTerm vide sa table de
-- handlers a chaque rechargement de config, un garde-fou dans `wezterm.GLOBAL`
-- empecherait de la reconstruire.
--
-- En cas d'echec, le serveur retombe sur sa propre fenetre : on est au pire dans
-- l'etat d'avant.
wezterm.on('mux-startup', function()
  local ok, err = pcall(function()
    wezterm.mux.spawn_window { workspace = M.PARKING }
  end)

  if not ok then
    wezterm.log_error('mux-startup: fenetre d amorcage non garee: ' .. tostring(err))
  end
end)

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
  -- domaine. `unix_domains` n'a pas `connect_automatically` : c'est NOUS qui
  -- demarrons le mux local, en tache de fond au lancement et seulement si un
  -- workspace actif en a besoin (cf. `M.start_local_mux`). Le laisser demarrer
  -- « a la demande » revenait a le demarrer sous la frappe, donc a geler le GUI.
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
