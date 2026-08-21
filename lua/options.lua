local wezterm = require 'wezterm'
local M = {}

local function color_scheme_for_appearance(appearance)
    appearance = appearance or 'Dark'

    if appearance:find('Dark') then
        return 'Catppuccin Mocha'
    end

    return 'Catppuccin Latte'
end

-- Detection du theme clair/sombre via l'API native WezTerm (supportee sur
-- Windows depuis 2023). On NE lance PLUS reg.exe : l'ancien code le faisait a
-- chaque update-status (toutes les 1000 ms) de facon SYNCHRONE sur le thread
-- GUI (~36 ms a chaque fois), ce qui ajoutait du jitter a toute l'interface,
-- y compris au moment d'ouvrir un pane. window:get_appearance() est un appel
-- natif sans process enfant ; le basculement auto clair/sombre reste actif.
local function current_color_scheme(window)
    if window then
        return color_scheme_for_appearance(window:get_appearance())
    end

    local appearance = wezterm.gui and wezterm.gui.get_appearance() or 'Dark'
    return color_scheme_for_appearance(appearance)
end

-- THEME PAR FENETRE, ET NON PAR CONFIG GLOBALE.
--
-- `config.color_scheme` est calcule UNE fois par evaluation de la config, hors
-- de toute fenetre. Les fenetres nees ensuite — celles des workspaces qu'on
-- cree en cours de session — heritent de cette valeur figee : c'est ainsi qu'un
-- nouveau workspace s'ouvrait en CLAIR alors que toutes les autres fenetres
-- etaient en sombre (constate le 2026-08-20). L'ancien handler ne rattrapait
-- pas le coup : il ne comparait qu'a une valeur unique dans `wezterm.GLOBAL`,
-- donc une fois la premiere fenetre corrigee, les suivantes n'avaient plus rien
-- qui les distingue et restaient sur le scheme fige.
--
-- On applique donc le scheme PAR FENETRE, depuis `window:get_appearance()`
-- (appel natif, sans le reg.exe synchrone d'avant), et par
-- `set_config_overrides` plutot que par `ReloadConfiguration` : un rechargement
-- de config invalide l'etat de rendu, repeint les panes mux en blocs et tue les
-- timers en vol. Les autres overrides sont conserves — `default_domain` porte
-- le choix local/distant de la fenetre (ALT+SHIFT+D).
--
-- Handler repose a CHAQUE evaluation du module, sans garde-fou `GLOBAL` : un
-- tel garde-fou empechait tout re-enregistrement apres que WezTerm eut vide sa
-- table de handlers au premier rechargement (meme piege que la maximisation
-- ci-dessous). Plusieurs exemplaires ne font aucun degat : l'action est
-- idempotente, elle ne fait rien quand le scheme est deja le bon.
function M.apply_dynamic_color_scheme()
    wezterm.GLOBAL.dynamic_color_scheme = wezterm.GLOBAL.dynamic_color_scheme
        or current_color_scheme()

    wezterm.on('update-status', function(window)
        if not wezterm.gui or not window then
            return
        end

        local ok, appearance = pcall(function()
            return window:get_appearance()
        end)

        if not ok then
            return
        end

        local color_scheme = color_scheme_for_appearance(appearance)

        -- MEMO PAR FENETRE, AVANT DE TOUCHER A LA CONFIG.
        --
        -- `get_config_overrides` recopie la table d'overrides et
        -- `set_config_overrides` INVALIDE le rendu de la fenetre. Les appeler a
        -- chaque tick pour reposer une valeur inchangee, c'est demander un
        -- repeint une fois par seconde et par fenetre — l'un des trois travers
        -- releves le 2026-08-21 sur le GUI fige (cf. lua/notify.lua).
        --
        -- La cle est SCALAIRE et par fenetre, comme la maximisation ci-dessous :
        -- `wezterm.GLOBAL` ne conserve pas la mutation d'une table imbriquee.
        local ok_id, window_id = pcall(function()
            return window:window_id()
        end)

        if not ok_id or window_id == nil then
            return
        end

        local flag = 'dynamic_color_scheme_' .. tostring(window_id)

        if wezterm.GLOBAL[flag] == color_scheme then
            return
        end

        local overrides_ok, overrides = pcall(function()
            return window:get_config_overrides()
        end)

        overrides = (overrides_ok and overrides) or {}

        if overrides.color_scheme == color_scheme then
            wezterm.GLOBAL[flag] = color_scheme
            return
        end

        overrides.color_scheme = color_scheme

        local applied = pcall(function()
            window:set_config_overrides(overrides)
        end)

        -- Memo pose seulement si l'ecriture a pris : sinon on reessaiera au tick
        -- suivant, ce qui est exactement ce qu'on veut d'un echec.
        if applied then
            wezterm.GLOBAL[flag] = color_scheme
            wezterm.GLOBAL.dynamic_color_scheme = color_scheme
        end
    end)
end

-- FENETRE MAXIMISEE (et non plein ecran : la barre des taches Windows doit
-- rester visible). Chaque fenetre GUI est maximisee UNE fois, la premiere fois
-- qu'un `update-status` la presente — donc au demarrage, et aussi pour les
-- fenetres ouvertes ensuite (workspace restaure). Une seule fois par fenetre :
-- l'utilisateur qui demaximise n'est pas contrarie au tick suivant.
--
-- POURQUOI `update-status` et pas les evenements de demarrage :
--   - `gui-startup` : sa seule presence inhibe la creation de la fenetre par
--     defaut (cf. lua/domains.lua), il faudrait la spawner soi-meme, donc
--     choisir un domaine au lancement — ce que cette config refuse.
--   - `gui-attached` : NE SE DECLENCHE PAS ici (verifie le 2026-08-19, journal
--     muet sur trois lancements). C'est l'evenement documente pour ce cas, mais
--     il suppose que le GUI se RATTACHE a un domaine ; avec `default_domain`
--     sur le domaine INTEGRE, il n'y a rien a rattacher.
-- `update-status` est le meme point d'accroche que le prechargement des
-- domaines (`run_preload_once`, lua/workspaces.lua), pour les memes raisons.
--
-- Journalisation dans `~/.wezterm-workspaces.log` (journal runtime deja utilise
-- par lua/workspaces.lua) et non via `wezterm.log_info` : le filtre de log par
-- defaut du GUI ne fait pas ressortir la cible `config`, ce qui rendait le
-- diagnostic aveugle. Hors du repo ET hors de `config_dir` : y ecrire
-- declencherait un rechargement de config a chaque ligne.
local startup_log_path = wezterm.home_dir .. '/.wezterm-workspaces.log'

local function startup_log(message)
    local file = io.open(startup_log_path, 'a')

    if not file then
        return
    end

    file:write(os.date('%Y-%m-%d %H:%M:%S') .. ' maximize: ' .. tostring(message) .. '\n')
    file:close()
end

function M.apply_startup_maximize()
    -- PAS de garde-fou d'enregistrement ici, contrairement au theme
    -- clair/sombre : un `wezterm.on` protege par une version dans
    -- `wezterm.GLOBAL` n'est enregistre QU'A LA PREMIERE evaluation de la
    -- config, et ce handler-la ne se declenche jamais (verifie le 2026-08-19 :
    -- « handler enregistre » dans le journal, jamais « handler appele »). Le
    -- handler `update-status` de lua/workspaces.lua, lui, s'enregistre a chaque
    -- evaluation du module et fonctionne. On s'aligne dessus.
    --
    -- Le prix a payer : plusieurs exemplaires du handler coexistent apres
    -- quelques rechargements, et chacun repart avec ses variables locales. L'etat
    -- « cette fenetre a deja ete traitee » vit donc dans `wezterm.GLOBAL`, seul
    -- endroit partage par tous, sous une CLE SCALAIRE par fenetre : `GLOBAL` ne
    -- conserve pas la mutation d'une table imbriquee sans reaffectation.
    wezterm.on('update-status', function(window)
        -- Uniquement cote GUI : le wezterm-mux-server local lit ce meme fichier.
        if not wezterm.gui or not window then
            return
        end

        local ok, window_id = pcall(function()
            return window:window_id()
        end)

        if not ok or window_id == nil then
            return
        end

        local flag = 'startup_maximize_done_' .. tostring(window_id)

        if wezterm.GLOBAL[flag] then
            return
        end

        wezterm.GLOBAL[flag] = true

        -- `maximize()` est idempotent, contrairement a `toggle_fullscreen()`
        -- (pas de `set_fullscreen(true)` dans l'API) : un exemplaire de handler
        -- en trop ne fait donc aucun degat.
        local applied, err = pcall(function()
            window:maximize()
        end)

        if applied then
            startup_log('fenetre ' .. tostring(window_id) .. ' maximisee')
        else
            startup_log('fenetre ' .. tostring(window_id) .. ' ERREUR ' .. tostring(err))
        end
    end)
end

function M.apply(config)
    local color_scheme = current_color_scheme()
    wezterm.GLOBAL.dynamic_color_scheme = color_scheme
    config.color_scheme = color_scheme
    config.font = wezterm.font('JetBrains Mono')
    config.status_update_interval = 1000
    config.exit_behavior = 'Close'

    -- TAILLE INITIALE des fenetres. Sans elle, WezTerm en cree a 80x24 — et
    -- depuis que la restauration cree la fenetre du workspace elle-meme (via
    -- `wezterm.mux.spawn_window`, pour ne jamais laisser le GUI sans fenetre a
    -- afficher), c'est cette taille-la que recoivent tous les workspaces
    -- restaures. Couper 80 colonnes avec un ratio capture a 79/79 donne alors un
    -- pane de UNE colonne : mesure le 2026-08-19 sur `modif-order` et
    -- `planning_tools`, illisibles. Les panes distants, eux, sont redimensionnes
    -- a la taille de la fenetre du client : une fenetre etroite ecrase la session
    -- entiere, y compris sur vibe.
    --
    -- Ce n'est PAS une taille de pane figee : les coupes restent des ratios (cf.
    -- `apply_layout`). C'est la taille de depart de la fenetre, que WezTerm
    -- ajuste ensuite.
    config.initial_cols = 159
    config.initial_rows = 40
    -- Domaines (tls_clients, default_domain, selecteur de demarrage) : voir
    -- lua/domains.lua. Ils ne sont plus declares ici.

    config.window_decorations = "RESIZE"
    -- Front-end OpenGL force : le defaut WebGpu sur Windows laisse par moments des
    -- regions non-repeintes apres un split/resize/restauration de workspace (panes
    -- qui semblent s'arreter avant le bas, framebuffer/bureau qui transparait). Le
    -- compositing transparent (opacity < 1.0 ci-dessous) rend le glitch visible.
    -- OpenGL est nettement plus stable sur Windows avec transparence.
    config.front_end = "OpenGL"
    config.window_background_opacity = 0.95

    config.window_padding = { left = 5, right = 5, top = 5, bottom = 5 }

    config.inactive_pane_hsb = {
        saturation = 0.9,
        brightness = 0.5,
    }
end

return M
