# Integration shell WezTerm pour les panes LOCAUX (PowerShell).
#
# Emet OSC 7 (« voici mon repertoire courant ») a chaque affichage du prompt.
# Sans cette sequence, WezTerm ignore ou se trouve le shell : un split ou un
# nouvel onglet repart alors du HOME au lieu du repertoire du pane courant.
#
# Pourquoi passer par le prompt et pas par le cwd du process : sous PowerShell,
# `Set-Location` ne change PAS le repertoire de travail du process
# (`[Environment]::CurrentDirectory` reste fige sur le dossier de demarrage).
# Ni WezTerm ni un helper Lua ne peuvent donc retrouver le repertoire reel
# autrement que par ce que le shell annonce lui-meme.
#
# Charge par `lua/domains.lua` (`default_prog`) et non par le profil utilisateur :
# la config doit rester auto-portante, sans etape d'installation manuelle.
#
# N'a AUCUN effet sur le domaine distant `vibe` : la ce sont le `default_prog` et
# le profil PowerShell du mux-server qui decident (cf. VIBE_TLS_SETUP.md).

# Dot-source multiple possible (rejeu de `last_command` au restore) : sans ce
# garde-fou, le prompt capture ci-dessous serait notre propre fonction, d'ou une
# recursion infinie a chaque affichage.
if ($global:WezTermOsc7Installed) { return }
$global:WezTermOsc7Installed = $true

# Prompt deja en place (defaut PowerShell, profil utilisateur, oh-my-posh...) :
# on l'enveloppe au lieu de le remplacer. Capture AVANT de definir le notre.
#
# On stocke le SCRIPTBLOCK (`$function:prompt`), surtout pas le FunctionInfo
# rendu par `Get-Command` : PowerShell reutilise et MUTE cet objet quand la
# fonction est redefinie, si bien que la reference « precedente » se mettait a
# designer notre propre prompt => recursion infinie a chaque affichage. Un
# ScriptBlock est immuable, il survit intact a la redefinition.
$global:WezTermInnerPrompt = $function:prompt

function global:prompt {
  $location = $ExecutionContext.SessionState.Path.CurrentLocation

  # Seul le provider FileSystem a un chemin exploitable : un prompt pose dans
  # HKLM:\ ou Cert:\ n'a rien a annoncer a WezTerm.
  if ($location.Provider.Name -eq 'FileSystem') {
    $esc = [char]27
    # Separateurs Windows convertis en '/' et espaces echappes : c'est une URL
    # file://, pas un chemin. WezTerm renormalise en 'C:\...' cote Lua.
    $path = [uri]::EscapeUriString(($location.ProviderPath -replace '\\', '/'))
    $Host.UI.Write("$esc]7;file://$env:COMPUTERNAME/$path$esc\")
  }

  if ($global:WezTermInnerPrompt) {
    & $global:WezTermInnerPrompt
  } else {
    "PS $($location.Path)$('>' * ($NestedPromptLevel + 1)) "
  }
}
