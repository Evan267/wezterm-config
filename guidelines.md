# Guidelines du projet

## Vue d'ensemble

Ce depot contient une configuration WezTerm modulaire en Lua. Le point d'entree est `wezterm.lua`, qui construit l'objet `config`, applique les plugins, charge les modules locaux, puis retourne la configuration a WezTerm.

Structure actuelle :

- `wezterm.lua` : point d'entree de la configuration.
- `lua/env.lua` : chargement des variables depuis `.env` (avec defauts internes).
- `lua/options.lua` : options visuelles et comportementales de base.
- `lua/domains.lua` : domaines local/distant (`tls_clients`, `default_domain`,
  selecteur de demarrage, bascule `ALT+SHIFT+D`).
- `lua/notify.lua` : notifications ephemeres dans le statut droit, partagees par
  `lua/workspaces.lua` et `lua/domains.lua`.
- `lua/status.lua` : barre native WezTerm et titres d'onglets.
- `lua/keys.lua` : raccourcis clavier personnalises et navigation de panneaux.
- `.env` / `.env.example` : variables par-machine (domaine mux). `.env` est
  gitignore ; `.env.example` est le modele versionne. Voir `VIBE_TLS_SETUP.md`.
- `WEZTERM_SHORTCUTS.md` : aide-memoire utilisateur des raccourcis.

## Etat actuel

La configuration active charge actuellement :

- `lua/options.lua` pour les options generales.
- `lua/domains.lua` pour les domaines local/distant.
- `lua/status.lua` pour la barre native WezTerm.
- `lua/keys.lua` pour les raccourcis clavier.

La persistance automatique de session n'est pas active dans cette configuration afin d'eviter les problemes rencontres sous Windows.

## Conventions de code

- Garder `wezterm.lua` minimal : initialisation, plugins, chargement des modules locaux, retour de `config`.
- Placer les options generales dans `lua/options.lua`.
- Placer les raccourcis clavier dans `lua/keys.lua`.
- Ajouter une fonction `M.apply(config)` dans chaque module Lua local.
- Eviter les effets de bord globaux sauf necessite WezTerm explicite, par exemple `wezterm.on(...)`.
- Preferer des noms explicites pour les helpers locaux, comme `split_nav` ou `is_vim`.
- Conserver les domaines de split en `CurrentPaneDomain` lorsque l'objectif est de garder le contexte du panneau actif.
- Externaliser les valeurs par-machine (hote, port, domaine mux) dans `.env`, lues via `lua/env.lua` ; ne pas les coder en dur dans les modules. Mettre a jour `.env.example` a chaque ajout de cle.

## Gestion des plugins

- Declarer les plugins dans `wezterm.lua` avec `wezterm.plugin.require(...)`.
- Appeler `plugin.apply_to_config(config)` juste apres la creation de `config`, sauf si le plugin impose un ordre different.
- Si un plugin expose des actions utilisees dans `lua/keys.lua`, passer explicitement l'objet plugin au module ou documenter clairement son usage.
- Quand un plugin est retire, mettre a jour les fichiers associes :
  - `wezterm.lua`
  - `lua/keys.lua`
  - `WEZTERM_SHORTCUTS.md`

## Raccourcis clavier

Les raccourcis doivent rester regroupes dans `lua/keys.lua`. La touche leader actuelle est :

- `CTRL+b`
- timeout : `1000ms`

La navigation de panneaux utilise les touches Vim :

- `CTRL+h/j/k/l` : changer de panneau.
- `META+h/j/k/l` : redimensionner le panneau actif.

Le helper `split_nav` transmet les touches a Neovim si la variable utilisateur `IS_NVIM` vaut `true`. Cela permet de conserver une navigation coherente entre WezTerm et Neovim.

## Domaines local / distant (`lua/domains.lua`)

WezTerm peut lancer les panes sur ce PC (domaine integre `local`) ou sur le
`wezterm-mux-server` de `vibe` (domaine mux TLS). Les deux cohabitent dans la
meme instance. Points de maintenance :

- **Ou vivent les domaines** : `tls_clients`, `default_domain` et l'evenement
  `gui-startup` sont dans `lua/domains.lua`, plus dans `lua/options.lua`. Ce
  dernier ne garde que les options visuelles/comportementales.
- **`default_domain = 'local'`** : la premiere fenetre doit pouvoir s'ouvrir
  meme si `vibe` est injoignable (VPN coupe, machine eteinte). L'ancien couple
  `default_domain = vibe` + `default_gui_startup_args = { 'connect', vibe }`
  rendait le demarrage dependant du reseau. Ne pas le retablir.
- **Selecteur de demarrage** : `gui-startup` spawne une fenetre locale puis pose
  la question « Ou travailler ? ». Le selecteur exige une **GuiWindow**, absente
  au moment de `gui-startup` : on reessaie via `call_after`, avec `update-status`
  en filet de securite (il fournit toujours une window valide). Drapeau one-shot
  dans `wezterm.GLOBAL` pour ne pas reposer la question a chaque reload de config.
- **Rattachement distant** (`ensure_attached`) : un domaine mux **detache refuse
  tout spawn**. Toute restauration ou creation sur un domaine distant doit
  appeler `domains.ensure_attached` AVANT de spawner, sinon le workspace s'ouvre
  vide. Ne pas regresser.
- **`domain:attach()` est asynchrone** : les fenetres distantes deja vivantes
  sont reflechies avec un delai. `adopt_remote_session` attend brievement avant
  de conclure « rien de vivant » et de convertir la fenetre d'amorcage en
  fenetre distante. Garde-fou : ne jamais fermer la derniere fenetre GUI
  (WezTerm quitterait) — d'ou le controle `#gui_windows() >= 2`.
- **Override `default_domain` par fenetre** : `ALT+SHIFT+D` passe par
  `window:set_config_overrides`. Tout autre `set_config_overrides` doit reporter
  `default_domain`, sinon il efface silencieusement le choix. C'est le cas du
  handler de bascule clair/sombre dans `lua/options.lua`. Ne pas regresser.
- **`CurrentPaneDomain` pour tabs et splits** : `M.spawn_tab` et `M.split_pane`
  epinglent explicitement `CurrentPaneDomain`. Sans cela, un tab ouvert dans un
  workspace distant depuis une fenetre restee locale par defaut partait sur la
  mauvaise machine.
- **Domaines d'overlay** : un pane d'`InputSelector` / `PromptInputLine` repond
  `TermWizTerminalDomain` a `get_domain_name()`. `domains.normalize` le filtre :
  il ne doit jamais atterrir dans `workspaces.json` ni etre propose comme cible.
- **Shell des panes locaux** (`M.local_shell_prog`, `config.default_prog`) : sous
  Windows, le defaut WezTerm est `cmd.exe` ; on lance PowerShell directement.
  Ordre de resolution : cle `SHELL_PROG` du `.env` si renseignee, sinon
  detection `pwsh.exe` puis `powershell.exe` via `where.exe`, sinon
  `powershell.exe` (present sur tout Windows). Hors Windows, `default_prog` est
  laisse a WezTerm (shell de login).
- **Detection du shell mise en cache** : elle passe par
  `wezterm.run_child_process`, donc par un process enfant. Resultat memorise
  dans `wezterm.GLOBAL` pour ne tourner qu'une fois par process et non a chaque
  rechargement de config. Meme raisonnement que pour la detection de theme : ne
  jamais deplacer cet appel dans un handler recurrent (`update-status`).
- **`default_prog` ne vaut QUE pour le domaine local.** Ce que le mux-server
  distant lance depend du `default_prog` de son propre `~/.wezterm.lua`, hors de
  ce repo. Ne pas chercher a le forcer depuis le client (cf. VIBE_TLS_SETUP.md).

## Workspaces (persistance et archivage)

Le module `lua/workspaces.lua` capture/restaure les workspaces dans
`workspaces.json` (gitignore, etat runtime par-machine). Points de maintenance :

- **Etat d'un workspace** : actif ou archive, porte par le champ optionnel
  `archived_at` (horodatage ISO, meme format que `saved_at`). Absence du champ =
  actif. L'archivage est un masquage doux et reversible, distinct de la
  suppression : aucune donnee n'est detruite.
- **Filtrage** : `list_workspaces(registry, filter)` avec `filter` valant
  `'active'` (defaut), `'archived'` ou `'all'`. Les listes du quotidien
  (ouverture `ALT+o`, cycle `ALT+←/→`) n'affichent que les actifs ; la suppression
  (`ALT+d`) liste tout.
- **Invariant a preserver** : `upsert_workspace` recopie le snapshot capture (qui
  ignore `archived_at`) ; il doit reporter `archived_at` depuis l'entree
  existante, sinon un simple `ALT+r` effacerait l'archivage. Ne pas regresser ce
  point.
- **Perte au redemarrage du mux-server** : les panes sont des process enfants du
  `wezterm-mux-server` de vibe ; s'il redemarre, ils meurent (aucune persistance
  disque cote mux-server). La reprise est **manuelle et fiabilisee**, pas
  automatique : `ALT+Shift+R` (`M.restore_all_active`) relance tous les
  workspaces actifs, chacun en nouvelle fenetre, en ignorant ceux deja vivants.
  Le decompte notifie distingue les deux raisons de saut (`deja ouverts`, `sans
  snapshot`) : un `0/3` muet ne permettait pas de diagnostiquer.
- **Vivacite d'un workspace** (`workspace_is_live` / `workspace_pane_count`) : un
  workspace n'est vivant que s'il porte au moins un **pane**. Ne pas se fier a
  `wezterm.mux.get_workspace_names()` (le nom survit sans aucune fenetre) ni a la
  seule presence d'une fenetre ou d'un tab : une coquille vide bloquait alors sa
  propre restauration (`ALT+Shift+R` renvoyait `0/3` en annoncant les workspaces
  « deja ouverts »). `workspace_pane_count` journalise l'etat vu du mux
  (`windows=/tabs=/panes=`) dans `workspaces-debug.log` : c'est le point d'entree
  pour diagnostiquer un saut inattendu. Ne pas regresser.
- **`workspace` obligatoire dans `mux.spawn_window`** : sans ce champ, la fenetre
  spawnee atterrit dans le workspace **actif**, pas dans celui restaure — le
  workspace cible restait une coquille vide pendant que son contenu s'ouvrait
  ailleurs. `restore_workspace_in_new_window` passe donc `workspace` et `domain`.
  Ne pas regresser.
- **Auto-sauvegarde** (`M.start_auto_save`, demarree depuis `wezterm.lua`) :
  boucle `wezterm.time.call_after` toutes les `auto_save_interval` s (60). Elle ne
  rafraichit que les workspaces **deja presents** dans le registre (jamais de
  creation implicite ; la creation reste `ALT+r`). Demarree une seule fois par
  process via le drapeau `wezterm.GLOBAL.workspace_auto_save_started` (un reload
  de config ne doit pas empiler une 2e boucle).
- **Invariant anti-ecrasement** : l'auto-save ne doit **jamais** ecraser une
  sauvegarde par un etat vide. Apres un redemarrage du mux-server, les panes
  morts sont filtres (pcall par pane dans `capture_pane`) et le snapshot devient
  vide : `snapshot_has_content` doit alors bloquer l'`upsert`. Ne pas regresser.
- **Shell de rejeu par domaine** (`pane_spawn`) : `last_command` est relancee via
  `<shell> -NoExit -Command <cmd>`. Le shell doit exister sur la machine DU PANE :
  `powershell.exe` en dur pour un pane distant (on ne peut pas sonder vibe, et il
  est present sur tout Windows), le shell local resolu pour un pane local. Hors
  Windows, pas de rejeu par shell (`-NoExit -Command` est une syntaxe PowerShell) :
  on retombe sur l'argv capture.
- **Denylist de rejeu** (`non_replayable_commands` / `is_replayable_command`) :
  certaines `last_command` ne sont jamais rejouees au restore, soit triviales
  (`cd`, `clear`, `ls`, `exit`, …), soit dangereuses (`wezterm-mux-server` :
  presente en `last_command` dans le registre, la rejouer relancerait un
  mux-server dans un pane). Comparaison sur le 1er token, basename sans `.exe`,
  minuscule.
- **Domaine d'un workspace** : champ `domain` au niveau du workspace **et** de
  chaque pane (capture via `pane:get_domain_name()`). Le pane prime, le
  workspace sert de repli. C'est ce qui permet d'ouvrir un workspace distant
  depuis une fenetre locale et inversement, sans rien basculer a la main.
  `upsert_workspace` reporte `domain` depuis l'entree existante quand la capture
  n'en remonte pas (panes morts apres un redemarrage du mux-server) : sans ce
  report, un workspace distant reviendrait en local a la restauration suivante.
  Meme invariant que pour `archived_at`. Ne pas regresser.
- **Migration** (`migrate_domains`, appelee par `load_registry`) : les entrees
  sans champ `domain` datent d'avant le multi-domaines et ne pouvaient venir que
  du mux distant ; elles sont estampillees `domains.REMOTE` et reecrites une
  fois. Sans cette migration, elles seraient restaurees en local (repli
  `DefaultDomain`, desormais `local`).
- **Domaine de spawn depuis un selecteur** (`workspace_domain_spawn`) : le `pane`
  passe au callback d'un `InputSelector` / `PromptInputLine` est le pane
  **d'overlay** (`TermWizTerminalPane`), pas un pane du domaine `vibe`. Tout
  `SwitchToWorkspace` declenche depuis un tel callback doit donc porter un
  `spawn` avec `domain = 'DefaultDomain'` : sans lui, WezTerm resout
  `CurrentPaneDomain` vers `TermWizTerminalDomain` et refuse le spawn (`cannot
  spawn panes in a TermWizTerminalPane`, visible dans
  `~/.local/share/wezterm/wezterm-gui.exe-log-*.txt`) — le workspace s'ouvrait
  alors **sans aucun pane**. Attention : `SwitchToWorkspace` sans `spawn` du tout
  n'est pas neutre, il retombe sur `SpawnCommand::default()`, donc sur
  `CurrentPaneDomain`. Seul le cas « workspace deja vivant » peut s'en passer (il
  ne spawne rien). Le domaine passe est desormais **celui du workspace** et non
  `DefaultDomain` : le defaut varie par fenetre depuis `ALT+SHIFT+D`, un
  workspace doit se restaurer la ou il a ete capture. Ne pas regresser.

## Documentation

- Mettre a jour `WEZTERM_SHORTCUTS.md` a chaque ajout, suppression ou modification de raccourci.
- Garder ce fichier centre sur l'usage quotidien.
- Garder `guidelines.md` centre sur les decisions de maintenance et les conventions du depot.

## Verification

Avant de considerer une modification terminee :

1. Verifier que `wezterm.lua` charge bien tous les modules necessaires.
2. Lancer une verification de configuration WezTerm si disponible :

   ```powershell
   wezterm cli list
   ```

3. Redemarrer ou recharger WezTerm pour confirmer que les plugins se chargent correctement.
4. Tester manuellement les raccourcis modifies.
5. Controler le diff Git :

   ```powershell
   git diff --check
   git status --short
   ```

## Points d'attention

- Les plugins WezTerm peuvent necessiter un acces reseau au premier chargement.
- Les raccourcis documentes ne sont fiables que si `lua/keys.lua` est effectivement applique dans `wezterm.lua`.
- Eviter de reintroduire un plugin de persistance de session sans validation specifique sous Windows.
- Detection du theme clair/sombre (`lua/options.lua`) : utiliser l'API native
  `window:get_appearance()` / `wezterm.gui.get_appearance()`. Ne PAS revenir a une
  detection via `reg.exe` : le handler `update-status` tourne toutes les 1000 ms et
  un appel `wezterm.run_child_process` y est synchrone sur le thread GUI (~36 ms a
  chaque tick), ce qui rend l'interface moins reactive (jitter a l'ouverture d'un
  pane inclus).
- Front-end de rendu (`lua/options.lua`) : forcer `config.front_end = "OpenGL"`. Le
  defaut WebGpu sur Windows laisse par moments des regions non-repeintes apres un
  split/resize/restauration de workspace (panes qui semblent s'arreter avant le bas,
  framebuffer/bureau qui transparait), glitch rendu visible par le compositing
  transparent (`window_background_opacity = 0.95`). Ne pas repasser a WebGpu sans
  revalider ce cas.
