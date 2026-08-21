local wezterm = require 'wezterm'
local M = {}

local default_duration = 2500
local error_duration = 5000

-- Notification courante affichee dans le statut droit, avec son horodatage
-- d'expiration. L'effacement est pilote par l'evenement update-status (qui
-- recoit une window valide a chaque tick) et non par un timer a window
-- capturee : ce dernier pouvait echouer silencieusement et laisser le message
-- affiche indefiniment.
local active_notification = nil

-- NE POSER QUE CE QUI CHANGE.
--
-- `set_right_status` marque la barre de statut SALE meme quand le texte est
-- identique : repose a chaque tick, il fait repeindre la fenetre en continu.
-- C'est l'une des trois sources de repeint inutile trouvees le 2026-08-21 dans
-- le GUI fige (boucle a 96 % d'un coeur en syscalls fenetre, sans aucune E/S,
-- cf. `switch_to_workspace` dans lua/workspaces.lua).
--
-- Memo par fenetre, et non global : deux fenetres n'affichent pas forcement la
-- meme chose, et l'une ne doit pas empecher l'autre de se mettre a jour.
local last_posted = {}

local function render(window)
  local text = active_notification and active_notification.text or ''

  local ok, window_id = pcall(function()
    return window:window_id()
  end)

  local key = (ok and window_id) or 'sans-id'

  if last_posted[key] == text then
    return
  end

  last_posted[key] = text

  pcall(function()
    window:set_right_status(text)
  end)
end

function M.info(window, message, duration)
  duration = duration or default_duration

  active_notification = {
    text = wezterm.format {
      { Attribute = { Intensity = 'Bold' } },
      { Foreground = { AnsiColor = 'Aqua' } },
      { Text = ' ' .. message .. ' ' },
    },
    -- os.time() est en secondes et update-status tourne toutes les 1000 ms : une
    -- resolution a la seconde suffit. Arrondi au superieur, minimum 1 s.
    expiry = os.time() + math.max(1, math.ceil(duration / 1000)),
  }

  render(window)
end

function M.error(window, message)
  M.info(window, message, error_duration)
end

-- Efface la notification une fois son delai ecoule. Pilote par update-status
-- pour disposer d'une window valide a chaque tick (~1 s).
wezterm.on('update-status', function(window)
  if not active_notification then
    return
  end

  if os.time() >= active_notification.expiry then
    active_notification = nil
  end

  render(window)
end)

return M
