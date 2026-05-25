local wezterm = require 'wezterm'
local M = {}

local DYNAMIC_COLOR_SCHEME_EVENT_VERSION = 5
local WINDOWS_THEME_REG_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize'
local DEFAULT_WSL_DISTRO = 'Debian'
local DEFAULT_SSH_DOMAIN = 'tailscale-100.108.20.16'
local DEFAULT_TMUX_SESSION = 'wezterm'

local function is_windows()
    return wezterm.target_triple:find('windows') ~= nil
end

local function wsl_distro()
    return os.getenv('WEZTERM_WSL_DISTRO') or DEFAULT_WSL_DISTRO
end

local function windows_path_to_wsl(path)
    if type(path) ~= 'string' then
        return path
    end

    local drive, rest = path:match('^([A-Za-z]):[/\\]?(.*)$')

    if not drive then
        return path:gsub('\\', '/')
    end

    rest = (rest or ''):gsub('\\', '/')
    return '/mnt/' .. drive:lower() .. (rest ~= '' and '/' .. rest or '')
end

local function color_scheme_for_appearance(appearance)
    appearance = appearance or 'Dark'

    if appearance:find('Dark') then
        return 'Catppuccin Mocha'
    end

    return 'Catppuccin Latte'
end

local function color_scheme_from_windows_registry()
    if not is_windows() then
        return nil
    end

    local ok, first, second, third = pcall(wezterm.run_child_process, {
        'reg.exe',
        'query',
        WINDOWS_THEME_REG_KEY,
        '/v',
        'AppsUseLightTheme',
    })

    if not ok then
        return nil
    end

    local output = nil

    for _, value in ipairs({ first, second, third }) do
        if type(value) == 'string' and value:find('AppsUseLightTheme') then
            output = value
            break
        end
    end

    if not output then
        return nil
    end

    if output:find('0x0') then
        return color_scheme_for_appearance('Dark')
    end

    if output:find('0x1') then
        return color_scheme_for_appearance('Light')
    end

    return nil
end

local function current_color_scheme(window)
    if is_windows() then
        return color_scheme_from_windows_registry()
    end

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
    config.ssh_domains = {
        {
            name = DEFAULT_SSH_DOMAIN,
            remote_address = '100.108.20.16',
            username = 'evan',
            multiplexing = 'None',
            default_prog = { 'tmux', 'new-session', '-A', '-s', DEFAULT_TMUX_SESSION },
        },
    }
    config.default_domain = DEFAULT_SSH_DOMAIN
    
    config.window_decorations = "RESIZE"
    config.window_background_opacity = 0.95
    
    config.window_padding = { left = 5, right = 5, top = 5, bottom = 5 }

    if is_windows() then
        local distro = wsl_distro()
        wezterm.GLOBAL.wsl_distro = distro
    end
    
    config.inactive_pane_hsb = {
        saturation = 0.9,
        brightness = 0.5,
    }
end

return M
