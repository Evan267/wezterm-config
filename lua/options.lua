local wezterm = require 'wezterm'
local env = require('lua/env')
local M = {}

local DYNAMIC_COLOR_SCHEME_EVENT_VERSION = 6
-- Variables du domaine mux chargees depuis `.env` (cf. lua/env.lua, .env.example).
local VIBE_DOMAIN = env.VIBE_DOMAIN     -- nom du domaine TLS cote client
local VIBE_ADDR = env.VIBE_ADDR         -- IP de vibe : le nom court WS871674 ne resout pas toujours hors interne (VPN)
local VIBE_TLS_PORT = env.VIBE_TLS_PORT -- port d'ecoute TLS du wezterm-mux-server sur vibe

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
            window:set_config_overrides({})
            window:perform_action(wezterm.action.ReloadConfiguration, pane)
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
    -- 'vibe' = machine distante (10.91.16.171 / WS871674) avec un wezterm-mux-server
    -- persistant (lance par tache planifiee, cf. VIBE_TLS_SETUP.md). Ce repo est la
    -- config du CLIENT uniquement ; le serveur a sa propre config ~/.wezterm.lua.
    --
    -- TLS direct avec certificats explicites. PAS de bootstrap_via_ssh : sur Windows il
    -- ne garde pas le mux-server vivant (process tue a la fermeture de la session SSH).
    -- PKI partagee, generee a la main, hors repo dans ~/.wezterm-tls (ca/client/server).
    local pki = wezterm.home_dir .. '\\.wezterm-tls\\'
    config.tls_clients = {
        {
            name = VIBE_DOMAIN,
            -- Cible TLS par IP : le nom court WS871674 ne se resout pas toujours hors interne.
            remote_address = VIBE_ADDR .. ':' .. VIBE_TLS_PORT,
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
    config.default_domain = VIBE_DOMAIN
    -- Au lancement, RATTACHER le mux-server vibe existant au lieu d'une fenetre vide.
    config.default_gui_startup_args = { 'connect', VIBE_DOMAIN }

    config.window_decorations = "RESIZE"
    config.window_background_opacity = 0.95

    config.window_padding = { left = 5, right = 5, top = 5, bottom = 5 }

    config.inactive_pane_hsb = {
        saturation = 0.9,
        brightness = 0.5,
    }
end

return M
