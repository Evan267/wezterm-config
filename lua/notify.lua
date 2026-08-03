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

local function render(window)
  pcall(function()
    window:set_right_status(active_notification and active_notification.text or '')
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
