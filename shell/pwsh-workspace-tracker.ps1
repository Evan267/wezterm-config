# WezTerm workspace tracker (PowerShell) — machine "vibe" (mux-server natif)
#
# Equivalent de shell/bash-workspace-tracker.bash, pour les panes PowerShell servis
# par le wezterm-mux-server de vibe. Il emet, a chaque invite :
#   - le cwd via OSC 7        -> alimente pane:get_current_working_dir()
#   - WEZTERM_WORKSPACE_CWD          (user var) -> capture du cwd par lua/workspaces.lua
#   - WEZTERM_WORKSPACE_LAST_COMMAND (user var) -> derniere commande interactive (relancee au restore)
#
# Installation sur vibe : sourcer ce fichier depuis le profil PowerShell.
#   notepad $PROFILE
#   . "$HOME\.config\wezterm\shell\pwsh-workspace-tracker.ps1"

# Fait confiance a la CA du proxy Fortinet pour les outils Node lances dans les
# panes (claude, npm, dev servers...). Le fichier est genere une seule fois sur
# vibe (cf. VIBE_TLS_SETUP.md, section « CA du proxy »). On l'expose ici car le
# mux-server, demarre avant la pose de la variable persistante, ne la transmet
# pas a ses panes : chaque shell la repose donc lui-meme, avant la 1ere commande.
if (-not $env:NODE_EXTRA_CA_CERTS -and (Test-Path "$HOME\node-extra-ca.pem")) {
  $env:NODE_EXTRA_CA_CERTS = "$HOME\node-extra-ca.pem"
}

$global:__WeztermWorkspaceLastCommand = ''

function global:__WeztermWorkspaceSetUserVar {
  param([string]$Name, [string]$Value)

  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
  $esc = [char]27
  $bel = [char]7
  [Console]::Write("$esc]1337;SetUserVar=$Name=$b64$bel")
}

function global:__WeztermWorkspaceEmitCwd {
  param([string]$Path)

  $esc = [char]27
  $bel = [char]7
  $uri = ($Path -replace '\\', '/')
  [Console]::Write("$esc]7;file://$env:COMPUTERNAME/$uri$bel")
}

# Conserve le prompt existant (par defaut ou personnalise) pour le rappeler ensuite.
if (-not (Test-Path Function:\__WeztermWorkspaceOriginalPrompt)) {
  Copy-Item Function:\prompt Function:\__WeztermWorkspaceOriginalPrompt -ErrorAction SilentlyContinue
}

function global:prompt {
  # N'emet que dans un pane WezTerm pour ne pas polluer d'autres terminaux.
  if ($env:WEZTERM_PANE) {
    $cwd = (Get-Location).Path
    __WeztermWorkspaceEmitCwd $cwd
    __WeztermWorkspaceSetUserVar 'WEZTERM_WORKSPACE_CWD' $cwd

    $last = (Get-History -Count 1).CommandLine
    if ($last -and $last -ne $global:__WeztermWorkspaceLastCommand) {
      $global:__WeztermWorkspaceLastCommand = $last
      __WeztermWorkspaceSetUserVar 'WEZTERM_WORKSPACE_LAST_COMMAND' $last
    }
  }

  if (Test-Path Function:\__WeztermWorkspaceOriginalPrompt) {
    return (& __WeztermWorkspaceOriginalPrompt)
  }

  return "PS $((Get-Location).Path)> "
}

# Capture la commande AU MOMENT DE LA SOUMISSION (avant qu'elle s'execute), pas
# entre deux invites. Sans ca, une commande au long cours (ex: claude) ne rend
# jamais la main et n'est jamais enregistree -> le restore ne peut pas la relancer.
# AddToHistoryHandler est non-invasif: il observe la ligne, ne rebinde pas Entree
# (donc l'edition multiligne reste intacte) et on renvoie $true pour conserver
# le comportement d'historique par defaut.
if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
  Set-PSReadLineOption -AddToHistoryHandler {
    param([string]$line)

    if ($env:WEZTERM_PANE -and $line -and $line.Trim()) {
      $global:__WeztermWorkspaceLastCommand = $line
      __WeztermWorkspaceSetUserVar 'WEZTERM_WORKSPACE_LAST_COMMAND' $line
    }

    return $true
  }
}
