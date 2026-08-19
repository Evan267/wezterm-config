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
panes dans le process GUI (domaine **intégré** `local`), dans un
`wezterm-mux-server` local (domaine unix `localmux`, démarré à la demande) **ou**
sur le `wezterm-mux-server` de `vibe` (`WS871674`), en TLS direct ; ce serveur
distant tourne avec sa propre config `~/.wezterm.lua` (hors de ce repo, bloc
`tls_servers`).

**Au lancement, WezTerm est sur le domaine intégré `local` et ne sollicite aucun
mux-server** : pas de socket à joindre, pas de serveur à démarrer, pas de session
à refléter. C'est ce qui rend le démarrage insensible à l'état des serveurs —
WezTerm se **termine** au lancement si son `default_domain` est injoignable, et
c'était le risque permanent de `default_domain = localmux`. Contrepartie assumée :
les panes du workspace de passage `default` meurent avec la fenêtre.

Les connexions dont les workspaces **actifs** ont besoin sont en revanche
**préchargées** ~1 s après l'ouverture (`run_preload_once` → `domains.preload`),
pour que leurs sessions soient déjà là au moment d'y basculer. Le préchargement
**sonde avant de rattacher** : `domain:attach()` est synchrone et gèlerait le GUI
le temps du timeout TCP. Le mux local n'est jamais *démarré* par le
préchargement, seulement rejoint s'il tourne déjà.

**Le choix d'un serveur est une question de création de workspace, pas de
lancement du terminal.** Il n'y a plus de sélecteur au démarrage : `ALT+n`
demande le domaine du nouveau workspace (mux local ou `vibe` — jamais l'intégré,
un workspace nommé doit survivre à la fermeture), et ce domaine est ensuite figé
dans `workspaces.json` (champ `domain`, par workspace et par pane). `ALT+SHIFT+D`
reste la bascule par fenêtre. `unix_domains` n'a pas `connect_automatically` : le
mux local ne démarre qu'au premier spawn qui le vise.

Ne pas supprimer le domaine intégré `local` : c'est celui du démarrage. En
revanche `workspaces.json` ne doit **jamais** le contenir : la capture
(`domains.persisted`) et la migration au chargement (`migrate_local_to_mux`)
réécrivent `local` en `localmux`, pour qu'un workspace de ce PC se restaure
toujours dans un mux.

Tout est déclaré dans `lua/domains.lua` (`unix_domains`, `tls_clients`,
`default_domain`) — plus dans `lua/options.lua`. Attention :
le mux local tourne sur cette machine et lit **ce même fichier de config**, donc
il hérite de `default_prog` mais fige la config à son démarrage. Tout changement
du domaine mux distant (port, IP, certificats dans `~/.wezterm-tls`) doit rester
cohérent avec le `~/.wezterm.lua` de vibe. Voir `VIBE_TLS_SETUP.md`.

L'état runtime vit **hors du dépôt ET hors du répertoire de config** :
`~/.wezterm-workspaces.json` (registre) et `~/.wezterm-workspaces.log` (journal).
WezTerm recharge toute sa configuration à la moindre écriture dans
`wezterm.config_dir` — même sur un fichier qui n'est pas du Lua — ce qui invalide
l'état de rendu et repeint les panes mux entièrement en blocs, en plus de tuer
les timers en vol. Ne jamais y remettre un fichier écrit en cours de session.

Corollaire pour toute session de travail sur ce dépôt : **éditer ces fichiers
perturbe l'affichage du terminal en cours d'utilisation**. Grouper les écritures
plutôt que de les enchaîner.

Les anciens `workspaces.json` / `workspaces-debug.log` restent dans `.gitignore`
tant qu'ils traînent sur les postes. Ne jamais versionner `.env` non plus ; seul
`.env.example` (modèle) est versionné.
