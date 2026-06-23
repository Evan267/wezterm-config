local wezterm = require 'wezterm'
local M = {}

-- Valeurs par defaut : utilisees si `.env` est absent (il est dans .gitignore,
-- donc pas garanti present sur une machine fraichement clonee) ou si une cle
-- manque. Le `.env` prime toujours. Voir `.env.example` pour le modele a copier.
local defaults = {
    VIBE_DOMAIN = 'vibe',
    VIBE_ADDR = '10.91.16.171',
    VIBE_TLS_PORT = '8131',
}

local function trim(s)
    return (s:gsub('^%s*(.-)%s*$', '%1'))
end

-- Parseur `.env` minimal : lignes `CLE=valeur`, commentaires `#` et lignes vides
-- ignores. Les guillemets simples/doubles entourant la valeur sont retires. Les
-- valeurs restent des chaines (suffisant ici : le port est utilise en
-- concatenation).
local function parse(path)
    local values = {}
    local file = io.open(path, 'r')
    if not file then
        return values
    end

    for line in file:lines() do
        local trimmed = trim(line)
        if trimmed ~= '' and trimmed:sub(1, 1) ~= '#' then
            local key, value = trimmed:match('^([%w_]+)%s*=%s*(.*)$')
            if key then
                value = trim(value)
                value = value:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
                values[key] = value
            end
        end
    end

    file:close()
    return values
end

local parsed = parse(wezterm.config_dir .. '\\.env')

for key, default_value in pairs(defaults) do
    M[key] = parsed[key] or default_value
end

return M
