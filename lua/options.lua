local wezterm = require 'wezterm'
local M = {}

local DYNAMIC_COLOR_SCHEME_EVENT_VERSION = 6
local VIBE_DOMAIN = 'vibe'
local VIBE_HOST = 'WS871674'   -- hostname de la machine vibe (mux-server)
local VIBE_TLS_PORT = 8131     -- port d'ecoute TLS du wezterm-mux-server sur vibe

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
    -- 'vibe' = WS871674, machine distante avec wezterm-mux-server persistant.
    -- Ce repo tourne sur les DEUX machines (cf. shell/pwsh-workspace-tracker.ps1),
    -- donc on branche selon le hostname : serveur TLS cote vibe, client TLS cote local.
    local is_vibe_server = wezterm.hostname() == VIBE_HOST

    if is_vibe_server then
        -- Cote serveur : exposer le mux via TLS. Au premier bootstrap SSH depuis le
        -- client, wezterm genere et echange les certificats automatiquement.
        -- Pre-requis cote vibe : pare-feu entrant TCP VIBE_TLS_PORT autorise.
        config.tls_servers = {
            {
                bind_address = '0.0.0.0:' .. VIBE_TLS_PORT,
            },
        }
    else
        -- Cote client : domaine TLS (et non plus SSH). Le PREMIER connect bootstrap
        -- les certs via SSH (lent, une seule fois) ; ensuite chaque connexion est une
        -- socket TLS directe vers le mux deja vivant -> on supprime le 'Checking
        -- server version' et le spawn d'un shell distant a chaque lancement.
        config.tls_clients = {
            {
                name = VIBE_DOMAIN,
                bootstrap_via_ssh = 'vibe',   -- resolu via ~/.ssh/config (HostName WS871674, User EBerger)
                remote_address = VIBE_HOST .. ':' .. VIBE_TLS_PORT,
                -- chemin court 8.3 (sans espace): le bootstrap SSH lance le wezterm
                -- distant via cmd.exe, qui couperait "C:\Program Files\..." a l'espace.
                remote_wezterm_path = 'C:\\PROGRA~1\\WezTerm\\wezterm.exe',
                -- Si le bootstrap se plaint d'un mismatch de hostname sur le cert,
                -- decommenter la ligne suivante :
                -- accept_invalid_hostnames = true,
            },
        }
        config.default_domain = VIBE_DOMAIN
        -- Au lancement, RATTACHER le mux-server vibe existant (et ses fenetres/workspaces
        -- deja vivants) au lieu de spawn une fenetre 'default' vide. Sans ca, le reopen
        -- repart sur un workspace neuf et donne l'impression que les sessions sont perdues.
        config.default_gui_startup_args = { 'connect', VIBE_DOMAIN }
    end

    config.window_decorations = "RESIZE"
    config.window_background_opacity = 0.95

    config.window_padding = { left = 5, right = 5, top = 5, bottom = 5 }

    config.inactive_pane_hsb = {
        saturation = 0.9,
        brightness = 0.5,
    }
end

return M
