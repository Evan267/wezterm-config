local wezterm = require 'wezterm'
local M = {}

local DYNAMIC_COLOR_SCHEME_EVENT_VERSION = 6

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

function M.apply_dynamic_color_scheme()
    if wezterm.GLOBAL.dynamic_color_scheme_event_version == DYNAMIC_COLOR_SCHEME_EVENT_VERSION then
        return
    end

    wezterm.GLOBAL.dynamic_color_scheme_event_version = DYNAMIC_COLOR_SCHEME_EVENT_VERSION
    wezterm.GLOBAL.dynamic_color_scheme = wezterm.GLOBAL.dynamic_color_scheme or current_color_scheme()

    wezterm.on('update-status', function(window, pane)
        if wezterm.GLOBAL.dynamic_color_scheme_event_version ~= DYNAMIC_COLOR_SCHEME_EVENT_VERSION then
            return
        end

        local color_scheme = current_color_scheme(window)

        if color_scheme and color_scheme ~= wezterm.GLOBAL.dynamic_color_scheme then
            wezterm.GLOBAL.dynamic_color_scheme = color_scheme
            -- On repart d'overrides vides pour forcer la relecture du scheme,
            -- MAIS `default_domain` doit survivre : c'est lui qui porte le choix
            -- local/distant de la fenetre (ALT+SHIFT+D, cf. lua/domains.lua).
            -- L'effacer renvoyait silencieusement la fenetre sur le domaine global.
            local overrides = window:get_config_overrides() or {}
            window:set_config_overrides({ default_domain = overrides.default_domain })
            window:perform_action(wezterm.action.ReloadConfiguration, pane)
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
