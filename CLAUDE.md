# CLAUDE.md

Consignes pour Claude lors du travail sur ce dépôt (configuration WezTerm Lua).

## Conventions

Les conventions de code, de maintenance et de structure sont décrites dans
`guidelines.md`. S'y référer et les respecter.

## Documentation à maintenir

À chaque modification, garder la doc associée à jour **dans le même commit** :

- `guidelines.md` — conventions du dépôt et décisions de maintenance.
- `WEZTERM_SHORTCUTS.md` — aide-mémoire des raccourcis ; mettre à jour à chaque
  ajout/suppression/modification de raccourci dans `lua/keys.lua`.
- `VIBE_TLS_SETUP.md` — procédure de mise en place du domaine mux TLS vers la
  machine distante `vibe`. **À maintenir à jour dès que change la configuration
  du domaine** : variables `VIBE_DOMAIN` / `VIBE_ADDR` / `VIBE_TLS_PORT` (définies
  dans `.env`, modèle `.env.example`, chargées par `lua/env.lua`), le bloc
  `tls_clients` et la PKI (`~/.wezterm-tls`) dans `lua/domains.lua`, ou toute
  étape de mise en place (pare-feu, redémarrage du mux-server).

## Spécificités multi-machines

Ce repo est la config **du client** (le poste local). Il peut faire tourner les
panes sur ce PC (domaine intégré `local`) **ou** sur le `wezterm-mux-server` de
`vibe` (`WS871674`), en TLS direct ; ce serveur tourne avec sa propre config
`~/.wezterm.lua` (hors de ce repo, bloc `tls_servers`). Le choix se fait au
démarrage (sélecteur « Où travailler ? »), par workspace (champ `domain` dans
`workspaces.json`) et par fenêtre (`ALT+SHIFT+D`). Le domaine par défaut est
`local` : l'ouverture de WezTerm ne doit jamais dépendre de la joignabilité du
serveur. Tout est déclaré dans `lua/domains.lua` (`tls_clients`,
`default_domain`, `gui-startup`) — plus dans `lua/options.lua`. Tout changement
du domaine mux (port, IP, certificats dans `~/.wezterm-tls`) doit rester cohérent
avec le `~/.wezterm.lua` de vibe. Voir `VIBE_TLS_SETUP.md`.

Ne jamais versionner l'état runtime ni la config par-machine (`workspaces.json`,
`workspaces-debug.log`, `.env`) : ils sont dans `.gitignore`. Seul `.env.example`
(modèle) est versionné.
