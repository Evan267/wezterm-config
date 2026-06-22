# Mise en place du domaine mux TLS « vibe »

Procédure complète pour faire fonctionner le terminal en s'attachant au
`wezterm-mux-server` persistant de la machine distante **vibe** via un
**domaine TLS**.

Objectif : supprimer le « Checking server version » long au lancement. Avec un
domaine SSH, chaque démarrage relançait un shell distant pour vérifier la
version avant de s'attacher. En TLS, le bootstrap SSH (lent) ne se fait
**qu'une seule fois** ; ensuite chaque `connect` ouvre une socket TLS directe
vers le mux déjà vivant.

## Architecture

- **vibe** = `WS871674`, machine distante qui fait tourner le
  `wezterm-mux-server` persistant (les workspaces/panes survivent à la
  fermeture de la fenêtre côté poste).
- **Poste local** = client, se connecte au domaine TLS nommé `vibe`.
- Ce repo est déployé sur **les deux machines**. `lua/options.lua` se branche
  selon `wezterm.hostname()` :
  - sur vibe → `tls_servers` (écoute le port TLS),
  - sur le poste → `tls_clients` (se connecte, bootstrap via SSH au 1ᵉʳ coup).

Constantes dans `lua/options.lua` :

| Constante | Valeur | Rôle |
|---|---|---|
| `VIBE_DOMAIN` | `vibe` | nom du domaine côté client |
| `VIBE_HOST` | `WS871674` | hostname de la machine vibe |
| `VIBE_TLS_PORT` | `8131` | port d'écoute TLS du mux-server |

Le host SSH `vibe` est résolu via `~/.ssh/config` (`HostName WS871674`,
`User EBerger`). Le bootstrap SSH utilise `remote_wezterm_path =
C:\PROGRA~1\WezTerm\wezterm.exe` (chemin court 8.3, car cmd.exe distant
couperait `C:\Program Files\...` à l'espace).

## Procédure de mise en place

### 0. Pré-requis (une seule fois)

- WezTerm installé sur le poste **et** sur vibe.
- `~/.ssh/config` sur le poste contient :
  ```
  Host vibe
    HostName WS871674
    User EBerger
  ```
- Le repo cloné des deux côtés dans `%USERPROFILE%\.config\wezterm`.

### 1. Côté vibe (serveur)

1. Récupérer la config à jour :
   ```powershell
   git -C $HOME\.config\wezterm pull
   ```
2. Ouvrir le port TLS dans le pare-feu (une seule fois) :
   ```powershell
   New-NetFirewallRule -DisplayName "WezTerm mux TLS" -Direction Inbound `
     -Protocol TCP -LocalPort 8131 -Action Allow
   ```
3. Redémarrer le `wezterm-mux-server` pour qu'il relise la config et ouvre le
   port (⚠️ ferme les panes vifs — faire un *save* de workspace avant si besoin) :
   ```powershell
   Get-Process wezterm-mux-server | Stop-Process -Force
   ```
   Pas besoin de le relancer à la main : le prochain `connect` depuis le poste
   le redémarre via SSH avec la bonne config.

### 2. Côté poste (client)

1. Récupérer la config à jour :
   ```powershell
   git -C $HOME\.config\wezterm pull
   ```
2. Relancer WezTerm. Le **premier** `connect` fait le bootstrap SSH (lent,
   génère et échange les certificats, affiche le « Checking server version »).
   Les lancements suivants passent directement en TLS et sont rapides.

### 3. Vérification

- Au 2ᵉ lancement, plus de « Checking server version » prolongé.
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

La variable persistante (`User`) ne prend effet que dans les **nouveaux**
process : ré-ouvrir les panes / le workspace pour que tout en hérite.

> Alternative si Node ≥ 22 sur vibe : `NODE_OPTIONS=--use-system-ca` (Node lit
> directement le magasin Windows, sans fichier à maintenir).

## Dépannage

- **Mismatch de hostname sur le certificat** au bootstrap → décommenter
  `accept_invalid_hostnames = true` dans le bloc `tls_clients` de
  `lua/options.lua`.
- **Connexion TLS refusée** → vérifier dans l'ordre : le pare-feu (port 8131
  entrant sur vibe), que le `wezterm-mux-server` tourne bien sur vibe, et que
  vibe a bien la version de la config avec `tls_servers` (`git pull`).
- **Re-bootstrap SSH à chaque reboot de vibe** → le mux-server ne survit pas au
  redémarrage de la machine. Le lancer au démarrage de vibe (tâche planifiée
  `wezterm-mux-server`) évite de repayer le bootstrap.
- **Forcer un nouveau bootstrap** (certs corrompus) → tuer le mux-server sur
  vibe puis relancer un `connect` depuis le poste ; WezTerm régénère les
  certificats.

## État runtime (non versionné)

`workspaces.json` et `workspaces-debug.log` sont régénérés localement sur
chaque machine et sont volontairement dans `.gitignore` : ne pas les committer,
sinon l'état d'une machine écraserait l'autre.
