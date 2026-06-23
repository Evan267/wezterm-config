# Mise en place du domaine mux TLS « vibe »

Procédure complète pour faire fonctionner le terminal en s'attachant au
`wezterm-mux-server` persistant de la machine distante **vibe** via un
**domaine TLS**.

Objectif : supprimer le « Checking server version » long au lancement. Avec un
domaine SSH, chaque démarrage relançait un shell distant pour vérifier la
version avant de s'attacher. En **TLS direct** (certificats explicites, **sans**
bootstrap SSH), chaque `connect` ouvre une socket TLS directe vers le mux déjà
vivant.

> Historique : une version précédente utilisait `bootstrap_via_ssh` (WezTerm
> générait et échangeait les certificats au 1ᵉʳ connect). Abandonné : sous
> Windows, la session SSH du bootstrap tue le `wezterm-mux-server` à sa
> fermeture. On utilise désormais une PKI fixe générée à la main et un
> mux-server lancé par tâche planifiée.

## Architecture

- **vibe** = `WS871674`, machine distante qui fait tourner le
  `wezterm-mux-server` persistant (les workspaces/panes survivent à la
  fermeture de la fenêtre côté poste). Il est lancé par une **tâche planifiée**
  (il ne survit pas au reboot) et configuré par son **propre** `~/.wezterm.lua`
  (hors de ce repo) qui déclare un `tls_servers` écoutant le port TLS.
- **Poste local** = client. **Ce repo est la config du client uniquement** :
  `lua/options.lua` déclare un `tls_clients` qui se connecte au domaine `vibe`.
  Il n'y a plus de branchement par `wezterm.hostname()`.
- **PKI partagée, générée à la main**, hors repo, dans `~/.wezterm-tls` des deux
  côtés (ni versionnée dans git, ni regénérée par WezTerm) :
  - `ca.pem` — autorité commune, présente des deux côtés ;
  - `client.crt` / `client.key` — côté poste ;
  - `server.crt` / `server.key` — côté vibe.
- La cible TLS est une **IP** (`VIBE_ADDR`), pas le nom : le CN du certificat ne
  matche pas, donc `accept_invalid_hostnames = true` dans `tls_clients` (le
  chiffrement et l'authentification mutuelle par certificat restent actifs).

Variables définies dans `.env` (modèle versionné : `.env.example`) et chargées
par `lua/env.lua`, puis consommées dans `lua/options.lua`. Le `.env` est dans
`.gitignore` : chaque machine a le sien (copier `.env.example`). Si une clé
manque, `lua/env.lua` retombe sur un défaut interne.

| Variable | Valeur | Rôle |
|---|---|---|
| `VIBE_DOMAIN` | `vibe` | nom du domaine côté client |
| `VIBE_ADDR` | `10.91.16.171` | IP de la machine vibe (`WS871674`) |
| `VIBE_TLS_PORT` | `8131` | port d'écoute TLS du mux-server |

Les chemins de la PKI sont construits dans `lua/options.lua` à partir de
`wezterm.home_dir` (`~/.wezterm-tls\client.crt`, `client.key`, `ca.pem`).

## Procédure de mise en place

### 0. Pré-requis (une seule fois)

- WezTerm installé sur le poste **et** sur vibe.
- Le repo cloné **sur le poste** dans `%USERPROFILE%\.config\wezterm` (côté vibe,
  c'est `~/.wezterm.lua` qui sert ; ce repo n'y est pas requis pour le mux).
- La PKI partagée déposée dans `~/.wezterm-tls` des deux côtés (cf. Architecture).
  Elle est **générée à la main** (openssl) hors de ce dépôt ; les fichiers
  existants ne sont pas regénérés par WezTerm.
- Sur le poste, créer le `.env` à partir du modèle (sinon `lua/env.lua`
  utilise ses défauts internes) :
  ```powershell
  Copy-Item $HOME\.config\wezterm\.env.example $HOME\.config\wezterm\.env
  ```

### 1. Côté vibe (serveur)

1. S'assurer que `~/.wezterm.lua` déclare un `tls_servers` écoutant sur le port
   TLS et référençant `~/.wezterm-tls\server.crt` / `server.key` / `ca.pem`.
2. Ouvrir le port TLS dans le pare-feu (une seule fois) :
   ```powershell
   New-NetFirewallRule -DisplayName "WezTerm mux TLS" -Direction Inbound `
     -Protocol TCP -LocalPort 8131 -Action Allow
   ```
3. Démarrer (ou redémarrer) le `wezterm-mux-server` pour qu'il relise sa config
   et ouvre le port (⚠️ un redémarrage ferme les panes vifs — *save* de
   workspace avant si besoin) :
   ```powershell
   Get-Process wezterm-mux-server | Stop-Process -Force
   ```
   Il est relancé par la **tâche planifiée** (cf. Dépannage) ; il n'y a plus de
   redémarrage via SSH depuis le poste.

### 2. Côté poste (client)

1. Récupérer la config à jour :
   ```powershell
   git -C $HOME\.config\wezterm pull
   ```
2. Vérifier que `~/.wezterm-tls` contient `ca.pem`, `client.crt`, `client.key`.
3. Relancer WezTerm : le `connect` ouvre directement une socket TLS vers le mux
   (plus de bootstrap SSH ni de « Checking server version » prolongé).

### 3. Vérification

- Dès le premier lancement, le `connect` est direct (pas de « Checking server
  version » prolongé).
- Les panes/workspaces de vibe sont présents :
  ```powershell
  wezterm cli list
  ```

## CA du proxy pour les outils Node (panes vibe)

Indépendant du mux TLS, mais à régler **sur vibe** car les panes y tournent
(`default_domain = vibe`). Le réseau THK passe par un proxy Fortinet qui fait de
l'inspection SSL : les outils **Node** (claude, npm, dev servers…) doivent faire
confiance à sa CA, sinon ils échouent en HTTPS ou polluent l'ouverture de
workspace.

**Symptôme** à l'ouverture d'un workspace :

```
Warning: Ignoring extra certs from C:\Users\eberger\certificat.pem, load failed:
error:10000002:SSL routines:OPENSSL_internal:system library
```

C'est **Node** (pas WezTerm) : `NODE_EXTRA_CA_CERTS` pointe vers un PEM absent ou
non définie sur vibe → Node ne charge pas la CA. En local la variable est déjà
posée et valide ; le seul trou est vibe.

**Correctif (dans un pane vibe, une seule fois).** On extrait les CA directement
du magasin Windows de vibe (machine du domaine → CA déjà présentes), ce qui
garantit un PEM propre :

```powershell
$out = "$HOME\node-extra-ca.pem"
Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root |
  Where-Object { $_.Subject -match 'Fortinet|THK-CA' } |
  Sort-Object Thumbprint -Unique |
  ForEach-Object {
    "-----BEGIN CERTIFICATE-----"
    [Convert]::ToBase64String($_.RawData,'InsertLineBreaks')
    "-----END CERTIFICATE-----"
  } | Set-Content -Encoding ascii $out

[Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', $out, 'User')
$env:NODE_EXTRA_CA_CERTS = $out
```

Les deux CA attendues : `FGT80FTK2000xxxx` (proxy Fortinet, indispensable) et
`THK-CA` (racine AD interne). Si le compteur de `BEGIN CERTIFICATE` est à 0,
ajuster le `-match` après `Get-ChildItem Cert:\LocalMachine\Root | Where Subject
-match 'Fortinet'`.

**Vérification :**

```powershell
# doit afficher "OK" SANS warning "ignoring extra certs"
node -e "require('tls').createSecureContext({}); console.log('CA chargees OK')"
# test reel a travers le proxy : status 200 attendu, aucune erreur de cert
node -e "require('https').get('https://registry.npmjs.org/',r=>{console.log(r.statusCode);r.destroy()}).on('error',e=>console.error(e.message))"
```

**Prise en compte dans les panes.** Le `wezterm-mux-server`, démarré avant la
pose de la variable, ne la transmet pas à ses panes (environnement figé). Plutôt
que de le redémarrer (ce qui tue les panes vifs), `shell/pwsh-workspace-tracker.ps1`
**repose la variable dans chaque pane** au démarrage du shell (si
`~\node-extra-ca.pem` existe et que la variable n'est pas déjà définie). Il
suffit donc de **ré-ouvrir le workspace** pour que les outils Node en héritent ;
inutile de toucher au mux-server.

> Alternative si Node ≥ 22 sur vibe : `NODE_OPTIONS=--use-system-ca` (Node lit
> directement le magasin Windows, sans fichier à maintenir).

## Dépannage

- **Mismatch de hostname sur le certificat** → vérifier que
  `accept_invalid_hostnames = true` est bien présent dans le bloc `tls_clients`
  de `lua/options.lua` (la cible étant une IP, le CN ne matche pas).
- **Connexion TLS refusée** → vérifier dans l'ordre : le pare-feu (port 8131
  entrant sur vibe), que le `wezterm-mux-server` tourne bien sur vibe, et que son
  `~/.wezterm.lua` déclare bien `tls_servers` sur le bon port.
- **Erreur de certificat / d'authentification** → vérifier que `~/.wezterm-tls`
  contient les bons fichiers des deux côtés (`ca.pem` commun, `client.*` sur le
  poste, `server.*` sur vibe) et qu'ils dérivent de la **même** CA.
- **Mux indisponible après un reboot de vibe** → le mux-server ne survit pas au
  redémarrage de la machine. La tâche planifiée `wezterm-mux-server` le relance
  au démarrage de vibe.
- **Certs corrompus / à renouveler** → regénérer la PKI à la main (openssl) et
  redéposer les fichiers dans `~/.wezterm-tls` des deux côtés. WezTerm ne les
  regénère **pas** (plus de bootstrap SSH).

## État runtime (non versionné)

`workspaces.json` et `workspaces-debug.log` sont régénérés localement sur
chaque machine et sont volontairement dans `.gitignore` : ne pas les committer,
sinon l'état d'une machine écraserait l'autre.
