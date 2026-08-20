# Guidelines du projet

## Vue d'ensemble

Ce depot contient une configuration WezTerm modulaire en Lua. Le point d'entree est `wezterm.lua`, qui construit l'objet `config`, applique les plugins, charge les modules locaux, puis retourne la configuration a WezTerm.

Structure actuelle :

- `wezterm.lua` : point d'entree de la configuration.
- `lua/env.lua` : chargement des variables depuis `.env` (avec defauts internes).
- `lua/options.lua` : options visuelles et comportementales de base.
- `lua/domains.lua` : domaines local/distant (`unix_domains`, `tls_clients`,
  `default_domain`, selecteur de domaine a la creation d'un workspace, bascule
  `ALT+SHIFT+D`).
- `lua/notify.lua` : notifications ephemeres dans le statut droit, partagees par
  `lua/workspaces.lua` et `lua/domains.lua`.
- `lua/status.lua` : barre native WezTerm et titres d'onglets.
- `lua/keys.lua` : raccourcis clavier personnalises et navigation de panneaux.
- `shell/wezterm.ps1` : integration shell des panes locaux (emission OSC 7),
  chargee par `lua/domains.lua` via `default_prog`.
- `.env` / `.env.example` : variables par-machine (domaine mux). `.env` est
  gitignore ; `.env.example` est le modele versionne. Voir `VIBE_TLS_SETUP.md`.
- `WEZTERM_SHORTCUTS.md` : aide-memoire utilisateur des raccourcis.

## Etat actuel

La configuration active charge actuellement :

- `lua/options.lua` pour les options generales.
- `lua/domains.lua` pour les domaines local/distant.
- `lua/status.lua` pour la barre native WezTerm.
- `lua/keys.lua` pour les raccourcis clavier.

Aucun plugin de persistance de session (type `resurrect`) n'est utilise : les
problemes rencontres sous Windows ont conduit a s'appuyer sur les mux-servers
(panes reellement vivants, cf. section Domaines) et sur `workspaces.json`
(snapshot rejouable, cf. section Workspaces).

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

WezTerm peut lancer les panes sur ce PC (mux local `localmux`, domaine unix) ou
sur le `wezterm-mux-server` de `vibe` (domaine mux TLS). Les deux cohabitent
dans la meme instance. Trois domaines existent donc, mais **deux seulement sont
proposes** :

| domaine | ou tournent les panes | survit a la fermeture du GUI |
| --- | --- | --- |
| `local` (integre) | process `wezterm-gui` | non — repli uniquement |
| `localmux` (unix) | `wezterm-mux-server` de ce PC | oui, jusqu'a la fin de session Windows |
| `vibe` (TLS) | `wezterm-mux-server` de `WS871674` | oui |

Points de maintenance :

- **Ou vivent les domaines** : `unix_domains`, `tls_clients` et `default_domain`
  sont dans `lua/domains.lua`, plus dans `lua/options.lua`. Ce dernier ne garde que les options
  visuelles/comportementales.
- **`default_domain = local` (le domaine INTEGRE)** : au lancement, WezTerm ne
  sollicite aucun mux-server — pas de socket a joindre, pas de serveur a
  demarrer, pas de session a refleter. C'est ce qui rend le demarrage insensible
  a l'etat des serveurs (cf. le point suivant : WezTerm se TERMINE si son domaine
  par defaut est injoignable, et c'etait le risque permanent de
  `default_domain = localmux`). Contrepartie assumee : les panes du workspace de
  passage `default` vivent dans le process GUI et meurent avec la fenetre.
  Un mux n'entre en jeu qu'a la CREATION d'un workspace (`ALT+n` demande lequel)
  ou a l'ouverture d'un workspace enregistre, qui porte son domaine.
  `unix_domains` n'a pas `connect_automatically` : le mux local ne demarre qu'au
  premier spawn qui le vise. Sous Windows le transport est un socket
  (`~/.local/share/wezterm/sock`) ; `socket_path` n'a pas besoin d'etre
  configure, et WezTerm demarre le serveur a la demande
  (`wezterm-mux-server --daemonize`).
- **Le mux local lit CETTE config** (meme machine, meme fichier) : il herite de
  `default_prog`, donc de l'integration OSC 7. Corollaire : il **fige** la
  config a son demarrage — modifier `default_prog` suppose de le redemarrer
  (`Stop-Process -Name wezterm-mux-server`), les panes deja vivants gardant leur
  shell. Il herite aussi du contexte de lancement : demarre depuis un shell
  eleve, tous les panes locaux deviennent eleves.
- **WezTerm n'affiche que les fenetres du workspace ACTIF.** Une fenetre d'un
  autre workspace existe toujours cote mux mais reste invisible, et reapparait
  des qu'on revient sur son workspace. Consequence a garder en tete avant de
  conclure a un bug d'affichage : « j'ai 2 fenetres a l'ouverture » = deux
  fenetres du MEME workspace (typiquement les deux `default` : celle du mux local
  et celle de vibe), pas un doublon cree par la config. Diagnostiquer en
  comparant `wezterm cli list` (tout ce que connait le mux) avec les fenetres
  reellement visibles.
- **Le mux-server spawne une fenetre a son demarrage**, et un handler
  `mux-startup` ne l'en empeche PAS (verifie : l'evenement se declenche bien,
  avec 0 fenetre a cet instant, mais le spawn par defaut a lieu ensuite ;
  contrairement a `gui-startup`, il n'est pas inhibe par la presence d'un
  handler). Inutile de retenter. Cette fenetre est celle que le GUI adopte au
  demarrage — elle n'est donc pas perdue, et rien ne s'accumule.
- **Les ids de panes different entre le GUI et le serveur** : un pane du mux
  n'a pas le meme `PANEID` dans `wezterm cli list` (vue GUI) et dans
  `wezterm cli --prefer-mux list` (vue serveur). Ne pas conclure « ce n'est pas
  le meme pane » sur cette base en debug ; comparer plutot le cwd ou le titre.
- **Le domaine integre `local` est celui du DEMARRAGE** : c'est le seul qui ne
  peut jamais etre injoignable. Il n'est pas propose dans le selecteur de
  domaine : un workspace NOMME doit survivre a la fermeture, donc mux local ou
  vibe. Ne pas le supprimer.
- **WezTerm se TERMINE si le domaine par defaut est injoignable** (verifie :
  `failed to connect to Socket(...); terminating` dans
  `~/.local/share/wezterm/wezterm-gui.exe-log-*.txt`). Le rattachement a lieu
  avant tout, aucun code Lua ne peut le rattraper — c'est exactement ce que la
  doc reprochait a `default_domain = vibe`. Assume pour le mux local (meme
  machine, demarre a la demande), inacceptable pour vibe : ne jamais retablir
  `default_domain = vibe` + `default_gui_startup_args = { 'connect', vibe }`.
  Un `--config default_domain=...` en ligne de commande **ne marche pas**,
  `M.apply` le reecrit.
- **AUCUN handler `gui-startup`, et c'est delibere** : sa seule presence inhibe
  la creation de la fenetre par defaut de WezTerm, qu'il faudrait alors spawner
  soi-meme — et toute fenetre spawnee la faisait DOUBLON avec celles du
  rattachement (4 fenetres au 4e demarrage, bug constate). Sans handler, WezTerm
  ouvre sa fenetre sur `default_domain`, donc sur le domaine integre. Contre-
  verite a ne pas reintroduire : « gui-startup doit creer une fenetre sinon
  WezTerm quitte » — verifie, c'est faux ; le quit observe venait du domaine par
  defaut **injoignable**.
- **Pas de selecteur au demarrage.** Le choix du serveur est une question de
  CREATION de workspace, pas de lancement du terminal (demande utilisateur du
  2026-08-19). L'ancienne sequence `gui-startup` + `ensure_session_window` +
  selecteur « Ou travailler ? » + `adopt_domain_session` a ete supprimee en bloc :
  elle existait pour rattraper l'asynchronisme du rattachement au demarrage, qui
  n'a plus lieu.
- **Un objet `GuiWindow` de callback est FIGE sur sa fenetre mux**
  (`restore_layout_in_window`, section Workspaces). Le `window` passe au
  callback d'un raccourci reste lie a la fenetre MUX qu'il avait au moment de la
  frappe : apres un `SwitchToWorkspace` il continue de rendre l'ANCIEN workspace,
  indefiniment tant que cette fenetre vit ailleurs dans le mux. L'attente du
  layout comparait justement `window:mux_window():get_workspace()` au nom cible
  et abandonnait donc TOUJOURS des lors qu'on venait d'un autre workspace —
  c'est-a-dire dans le cas normal. Trace le 2026-08-19, matin et soir :
  « restore layout gave up workspace=modif-order » 3 s apres avoir bascule sur
  `chaud-devant`, alors que le spawn avait bien cree sa fenetre. Cout reel : la
  disposition n'etait JAMAIS rejouee, il ne restait que la fenetre a un pane
  creee par le spawn, et l'auto-save finissait par enteriner cet etat ampute.
  La fenetre cible est desormais celle que `spawn_workspace_window` vient de
  creer cote mux : on la garde sous la main au lieu de la redemander. Ne jamais
  reintroduire un test d'egalite de workspace sur `window:mux_window()`.
- **La fenetre d'amorcage du mux-server se GARE A LA SOURCE, elle ne se
  pourchasse pas** (`mux-startup`, dans `lua/domains.lua`). Un
  `wezterm-mux-server` ouvre une fenetre pour lui-meme a son demarrage s'il n'a
  aucun pane dans son domaine par defaut. Un handler `mux-startup` ne l'inhibe
  pas, contrairement a `gui-startup` — mais il peut la DEVANCER : creer ce
  premier pane nous-memes, dans le workspace de parking, dispense le serveur d'en
  creer un. Sans cela, cette fenetre atterrit dans `default` et le client la
  reimporte a chaque rattachement.
  - **Ne pas revenir a un balayage.** La version precedente
    (`evict_foreign_windows`) inspectait toutes les fenetres importees toutes les
    0,5 s pendant 25 s apres chaque rattachement, en lisant le repertoire de
    CHAQUE pane — un aller-retour reseau synchrone par pane distant, sur le
    thread GUI. Elle a fige WezTerm (`Responding=False`, journal arrete net) et a
    ete supprimee (e5060dc). Le parking a la source n'a ni timer, ni balayage, ni
    lecture de pane.
  - **On DEPLACE, on ne ferme pas** : `MuxWindow` n'expose ni `close` ni `kill`
    (verifie dans le binaire ; `set_workspace`, si). Une fenetre garee reste
    accessible, elle ne gene simplement plus — le parking n'est jamais le
    workspace actif.
- **La fenetre d'un workspace, c'est NOUS qui la creons** — et le detour par le
  parking en fait partie. Voir la section Workspaces
  (`spawn_workspace_window`) : `SwitchToWorkspace { spawn = ... }` depose la
  fenetre dans le workspace ACTIF, `workspace = <cible>` au spawn ne corrige que
  le cote client, et seul `set_workspace` remet le mux-server d'accord. Les deux
  approches naives ont chacune ete essayees et annulees (8a40e21/38ccd14, puis le
  retour a `SwitchToWorkspace` lui-meme) : ne pas refaire le tour.
- **UNE SEULE FENETRE OUVERTE, TOUJOURS.** Invariant du depot, pose le
  2026-08-19 : rien dans cette config ne doit ouvrir une fenetre a cote. Le mode
  « ouvrir en nouvelle fenetre » (`restore_workspace_in_new_window`, le mode
  `new` de `restore_workspace`, le raccourci `ALT`+`SHIFT`+`o`) a donc ete
  supprime en bloc. Un workspace s'ouvre la ou on est ; c'est WezTerm qui revele
  la fenetre du workspace cible, une par workspace, jamais deux a la fois.
  - Ce que WezTerm fait de son cote et qu'il ne faut pas confondre avec un bug :
    **une fenetre mux <-> une fenetre OS**. A la bascule il DETRUIT la fenetre OS
    du workspace quitte et en CREE une pour celui ou l'on arrive. Verifie le
    2026-08-19 : une seule fenetre visible dans le systeme, et `windows=1` par
    workspace cote mux, bascule apres bascule. Rien ne s'accumule ; c'est une
    nouvelle fenetre OS, pas une fenetre en trop.
  - **Ce que le mux-server ajoute** : il spawne sa propre fenetre a son
    demarrage. Elle est desormais garee dans le workspace de parking par le
    handler `mux-startup` (voir plus haut), donc invisible. L'API Lua n'offre
    aucun moyen de FERMER une fenetre mux : ni `MuxWindow` ni `MuxTab` n'exposent
    de `close`/`kill`. Ne pas perdre de temps a chercher, c'est verifie — c'est
    aussi pourquoi on gare au lieu de fermer.
- **Taille des splits en RATIO, jamais en absolu** (`apply_layout`) : la coupe
  est calculee comme `second_size / total` et passee en fraction a
  `pane:split`, donc relative a la fenetre DU MOMENT. Un workspace capture en 159
  colonnes se rouvre aux memes proportions dans une fenetre plus petite. Ne pas
  revenir a un nombre de cellules calcule sur les dimensions capturees. Le
  `+ 0.005` compense le `floor` applique cote Rust
  (`SplitSize::Percent((size * 100.).floor())`), qui faisait perdre un point de
  pourcentage a chaque restauration sur certaines valeurs.
- **Sauvegarde a l'EVENEMENT, avec anti-rebond de FIN** (`save_soon`). On
  n'enregistre que le workspace qui vient de bouger, et seulement sur une action
  dont on maitrise la frequence : split, nouvel onglet, renommage, fermeture d'un
  pane ou d'un onglet, redimensionnement, ouverture d'un workspace.
  - **L'anti-rebond doit etre de FIN, pas de debut** : chaque demande annule la
    precedente (jeton par workspace), la capture part N secondes apres la
    DERNIERE. C'est ce qui permet de brancher un redimensionnement — maintenir
    une touche ou trainer le bord d'une fenetre emet des dizaines d'evenements
    pour une seule ecriture. Verifie le 2026-08-19 : treize bascules de workspace
    en trois secondes, deux captures au total.
  - **Ne PAS brancher `user-var-changed`.** Le shell annonce son repertoire a
    chaque invite, mais la cadence est imprevisible : une TUI qui redessine et
    l'evenement part en rafale. Essaye le meme soir, WezTerm s'est fige — chaque
    rafale relancait une capture, donc un aller-retour reseau par pane distant
    sur le thread GUI. Meme cause que le balayage des fenetres intruses.
  - **Fermetures : pas d'evenement.** Ni `pane-exited` ni `tab-closed` n'existent
    (verifie dans le binaire ; `window-resized` et `window-focus-changed`, si).
    Les raccourcis de fermeture sont donc enveloppes dans un `action_callback`
    qui signale le changement, avec un delai laissant passer la confirmation.
- **Etat runtime HORS de `config_dir`** : le registre et le journal sont ecrits
  dans `~/.wezterm-workspaces.json` et `~/.wezterm-workspaces.log`, **jamais**
  dans `wezterm.config_dir`. WezTerm surveille son repertoire de config et
  recharge TOUTE la configuration a la moindre ecriture dedans, meme sur un
  fichier qui n'est pas du Lua : une seule ligne de journal declenche 3
  reevaluations. Or un rechargement invalide l'etat de rendu — les panes servis
  par un mux-server doivent re-recuperer leurs lignes et s'affichent ENTIEREMENT
  EN BLOCS en attendant. C'est LA cause du bug « carres », longtemps impute au
  front-end graphique puis au reseau ; symptomes qui le trahissent : apparition
  sans rien toucher (cadence de l'auto-save) et a chaque restauration (qui
  journalise plusieurs fois). Il tue aussi les timers en vol, donc la boucle
  d'auto-sauvegarde. `migrate_state_location` reprend l'ancien registre une seule
  fois. **Ne jamais rendre a ce module un chemin d'ecriture sous `config_dir`.**
- **Une reconstruction EN VOL bloque les autres** (`build_in_flight`, cle plate
  par workspace dans `wezterm.GLOBAL`, avec echeance) : le SwitchToWorkspace cree
  la fenetre et le rejeu de la disposition n'arrive qu'ensuite ; pendant ces
  quelques centaines de ms le workspace parait encore vide, donc une deuxieme
  frappe en relance une par-dessus. Constate le 2026-08-19 : `test-restore`
  reconstruit a 21:01:37 puis a 21:01:39, d'ou des fenetres « de partout ».
- **AMORCAGE : demarrer, puis rattacher — jamais sous une frappe.**
  `domain:attach()` est SYNCHRONE sur le thread GUI. Deux couts distincts s'y
  cachent, et les confondre est la cause de tous les gels mesures sur ce depot :
  - **demarrer** un mux-server (creation de process, lecture de config, shell) :
    4,4 s mesurees le 2026-08-20 sur le mux local, interface entierement morte,
    et cela tombait pile sur la frappe qui ouvrait le premier workspace local
    (journal GUI : « Will try spawning the server » a 09:18:06, workspace ouvert
    a 09:18:09) ;
  - **joindre** un serveur injoignable : 12 s mesurees le 2026-08-19 sur vibe,
    le temps du timeout TCP.
  D'ou la sequence, en deux temps (`run_preload_once`) :
  - `t+0` : `domains.start_local_mux()` — `wezterm.background_child_process`,
    qui n'attend RIEN, contrairement a `run_child_process`. Uniquement si un
    workspace actif vit sur le mux local. C'est la seule operation vraiment
    couteuse et on ne peut pas la raccourcir : on la lance donc au plus tot.
    Possible seulement depuis que la fenetre d'amorcage du serveur est garee
    (cf. `mux-startup`) ; c'est elle qui interdisait ce demarrage anticipe.
  - `t+2 s` : `domains.preload()` rattache. Rattacher un serveur QUI TOURNE est
    bon marche ; le distant est en plus sonde avant (poignee de main TCP bornee
    a 800 ms, sans TLS — mesure a 407 ms serveur joignable), pour ne jamais
    payer le timeout.
  - **Sous une frappe, on ne rattache jamais** : `restore_workspace` interroge
    `domains.is_attached` (lecture d'etat pure), et si le domaine n'est pas
    pret il demande le demarrage, notifie, et se rappelle en differe
    (`ATTACH_RETRY_DELAY`, six essais). Le terminal reste vivant et
    l'utilisateur voit un message au lieu d'un fige. Ne pas remettre
    `ensure_attached` dans un chemin declenche par une touche — y compris dans
    la boucle de `restore_all_active`, ou il sondait tous les domaines d'affilee
    avant la moindre ouverture.
- **Les handlers d'evenement ne sont enregistres QU'UNE FOIS par process**
  (`wezterm.GLOBAL.workspace_handlers_version`, meme garde-fou que le theme dans
  `lua/options.lua`). Chaque rechargement de config reevalue les modules ; un
  `wezterm.on` sans garde-fou empile un handler de plus a chaque fois, et sur ce
  depot les rechargements sont frequents (toute ecriture dans `config_dir`).
- **Rattachement** (`ensure_attached`) : un domaine mux **detache refuse tout
  spawn**. Toute restauration ou creation sur un domaine mux — `localmux`
  compris, seul `local` est exempt — doit donc etre rattachee AVANT de spawner,
  sinon le workspace s'ouvre vide. Le rattachement lui-meme est bloquant : il se
  fait au demarrage ou en differe, jamais dans le fil d'une frappe (voir
  l'amorcage ci-dessus). Ne pas regresser.
- **`is_local` vs `is_remote`** : la distinction porte sur la MACHINE, pas sur
  la persistance. `is_local` couvre `local` ET `localmux` ; c'est elle qui decide
  du shell de rejeu (cf. section Workspaces) et de la couleur du statut. Un
  `name ~= LOCAL` en dur ferait passer le mux local pour du distant.
- **`domain:attach()` est asynchrone**, et le budget d'attente depend de la
  MACHINE : `attach_attempts` (1,5 s) pour le mux local, `attach_attempts_remote`
  (5 s) pour vibe, dont le rattachement passe par une poignee de main TLS
  reseau. Conclure trop tot « aucune session vivante » ferait ouvrir un workspace
  `vibe` neuf alors que la session existe — elle apparaitrait juste apres, en
  doublon. Les fenetres deja vivantes du domaine sont reflechies avec un delai. `adopt_domain_session` attend brievement avant
  de conclure « rien de vivant ». Trois issues : reprendre une fenetre reflechie
  (sans rien fermer), rester sur place si la fenetre courante tourne deja sur
  le domaine vise (cas normal du mux local), sinon ouvrir une session sur ce
  domaine. Garde-fou : ne jamais fermer la derniere fenetre GUI (WezTerm
  quitterait) — d'ou le controle `#gui_windows() >= 2`.
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
- **Heritage du repertoire courant** (`shell/wezterm.ps1`, `M.local_prog`) : un
  split ou un nouvel onglet local repartait du HOME au lieu du repertoire du
  pane courant. WezTerm ne connait le cwd d'un pane que si le shell le lui
  annonce par **OSC 7** ; aucun profil PowerShell local n'existait pour le
  faire (sur `vibe`, c'est le profil du serveur qui s'en charge). Deux pieges a
  ne pas reintroduire :
  - Le repli « lire le cwd du process » (`get_foreground_process_info().cwd`)
    ne marche PAS ici : sous PowerShell, `Set-Location` ne modifie pas le
    repertoire de travail du process (`[Environment]::CurrentDirectory` reste
    fige sur le dossier de demarrage). Seule l'annonce par le shell est fiable.
  - Dans le script, le prompt precedent est capture via `$function:prompt`
    (ScriptBlock immuable) et **jamais** via `Get-Command prompt` : PowerShell
    mute ce `FunctionInfo` a la redefinition, la reference « precedente »
    devenait notre propre prompt et bouclait a l'infini.
  L'integration est chargee par `default_prog` et non installee dans le profil
  utilisateur : la config reste auto-portante, sans etape manuelle. `M.local_prog`
  est le point unique qui construit l'argv local (aussi utilise par le rejeu de
  `last_command`, cf. section Workspaces) — ne pas reconstruire cet argv ailleurs.
- **Detection du shell mise en cache** : elle passe par
  `wezterm.run_child_process`, donc par un process enfant. Resultat memorise
  dans `wezterm.GLOBAL` pour ne tourner qu'une fois par process et non a chaque
  rechargement de config. Meme raisonnement que pour la detection de theme : ne
  jamais deplacer cet appel dans un handler recurrent (`update-status`).
- **`default_prog` ne vaut que pour CETTE machine** (domaine integre et mux
  local, qui partagent ce fichier de config). Ce que le mux-server distant lance
  depend du `default_prog` de son propre `~/.wezterm.lua`, hors de ce repo. Ne
  pas chercher a le forcer depuis le client (cf. VIBE_TLS_SETUP.md).

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
- **Perte au redemarrage du mux-server** : les panes sont des process enfants
  d'un `wezterm-mux-server` — celui de vibe, ou le mux local (qui meurt avec la
  session Windows : deconnexion, reboot). S'il redemarre, ils meurent (aucune
  persistance disque cote mux-server). La reprise est **manuelle et fiabilisee**, pas
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
- **La fenetre d'un workspace se cree dans le PARKING, puis se RENOMME**
  (`spawn_workspace_window`, unique porte d'entree : restauration, entree sans
  snapshot, et creation `ALT+n`). C'est le point le plus contre-intuitif du
  module, et il a deja ete casse deux fois dans les deux sens :
  - `SwitchToWorkspace { spawn = ... }` ne cree PAS la fenetre dans le workspace
    demande. WezTerm la cree dans `mux.active_workspace()`
    (wezterm-gui/src/spawn.rs), et `ClientDomain::spawn` envoie cette meme
    valeur au mux-server. Or `reconcile_workspace`
    (wezterm-gui/src/frontend.rs) constate que le workspace tout juste active
    est encore vide et se rabat d'autorite sur le premier workspace non vide
    (`default`) ; son garde-fou `switching_workspaces` est un booleen unique du
    front-end, que la premiere bascule aboutie efface pour toutes celles encore
    en vol. Deux ouvertures de suite (`ALT+SHIFT+R`) suffisent donc a l'ouvrir.
    Constat du 2026-08-20 : deux fenetres `default` cote mux-server portant le
    cwd de `chaud-devant`, aucune fenetre ou poser la disposition, et une volee
    de fenetres parasites a chaque rattachement suivant, ces fenetres survivant
    au GUI.
  - Passer `workspace = <cible>` a `mux.spawn_window` ne suffit pas non plus :
    ce champ ne corrige que le cote CLIENT. Le mux-server, lui, garde
    l'etiquette du workspace actif et ressort les panes dans le workspace
    courant au rattachement suivant (le piege de 8a40e21, revert 38ccd14).
  - Seul `MuxWindow:set_workspace` corrige les deux : il emet
    `WindowWorkspaceChanged`, que le client traduit en `SetWindowWorkspace` pour
    le serveur. D'ou la naissance dans le parking : `set_workspace` ne notifie
    rien si le nom ne change pas, la fenetre doit donc naitre AILLEURS que dans
    sa cible. Le parking n'etant jamais l'actif, rien n'apparait a l'ecran.
  - La bascule qui suit ne porte alors plus de `spawn` : elle rejoint une
    fenetre existante. Ne pas regresser.
- **Fenetre d'amorcage du mux-server** (`mux-startup`, dans `lua/domains.lua`) :
  `wezterm-mux-server` ouvre une fenetre a son demarrage s'il n'a aucun pane
  dans son domaine par defaut. Sans workspace demande, elle atterrit dans
  `default` et le GUI la reimporte a chaque rattachement. On ne peut pas
  l'empecher, on la CHOISIT : le handler cree ce premier pane dans le parking,
  ce qui dispense le serveur d'en creer un. Surtout, ne pas revenir a un
  balayage des fenetres importees pour les deloger apres coup : cette version-la
  a fige le GUI (cf. e5060dc).
- **Auto-sauvegarde** (`M.start_auto_save`, branchee depuis `wezterm.lua`) :
  boucle `wezterm.time.call_after` toutes les `auto_save_interval` s (60), qui
  rafraichit les snapshots des workspaces deja presents dans le registre.
  - **Armee depuis un EVENEMENT, jamais depuis le scope du fichier de config.**
    Un `wezterm.time.call_after` pose pendant l'evaluation de la config ne se
    declenche JAMAIS. Mesure le 2026-08-18 : GUI demarre depuis 9 min, registre
    jamais reecrit, zero ligne `enregistre` au journal. L'ancien drapeau
    `workspace_auto_save_started` figeait en plus la panne pour de bon, en
    interdisant tout reamorcage. `update-status` est le point d'accroche : il
    tire des le premier rendu et rien ne l'inhibe.
  - **Un reload de config TUE les timers en vol**, et il y en a a chaque ecriture
    dans `config_dir` — ou vit justement `workspaces.json`. Une boucle armee une
    seule fois est donc une boucle morte. D'ou une generation
    (`workspace_auto_save_generation`) et un battement de coeur
    (`workspace_auto_save_heartbeat`) dans `wezterm.GLOBAL` : `arm_auto_save` ne
    relance que si aucun battement n'est arrive depuis 3 scrutations, et une tick
    dont la generation n'est plus celle du GLOBAL s'arrete d'elle-meme. Deux
    boucles ne peuvent donc pas coexister. Ne pas revenir a un drapeau booleen.
  - **Une erreur de scrutation se journalise** (`auto-save erreur: ...`). Un
    pcall muet ici, c'est une auto-save qui cesse de sauvegarder sans que rien ne
    le dise — exactement ce qui est arrive le 2026-08-19.
- **Invariant anti-ecrasement** : l'auto-save ne doit **jamais** ecraser une
  sauvegarde par un etat vide. Apres un redemarrage du mux-server, les panes
  morts sont filtres (pcall par pane dans `capture_pane`) et le snapshot devient
  vide : `snapshot_has_content` doit alors bloquer l'`upsert`. Ne pas regresser.
- **Shell de rejeu par domaine** (`pane_spawn`) : `last_command` est relancee via
  `<shell> -NoExit -Command <cmd>`. Le shell doit exister sur la machine DU PANE :
  `powershell.exe` en dur pour un pane distant (on ne peut pas sonder vibe, et il
  est present sur tout Windows) ; pour un pane de ce PC (`local` comme
  `localmux`, d'ou `domains.is_local`), `domains.local_prog(cmd)`,
  qui ajoute l'integration OSC 7 au shell resolu — un pane restaure doit annoncer
  son cwd comme les autres, sinon ses propres splits repartiraient du HOME. Hors
  Windows, `local_prog` rend nil (`-NoExit -Command` est une syntaxe PowerShell) :
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
- **Migrations** (`migrate_domains`, appelee par `load_registry`), idempotentes :
  - entrees sans champ `domain` : elles datent d'avant le multi-domaines et ne
    pouvaient venir que du mux distant ; estampillees `domains.REMOTE`. Sans
    cette migration, elles seraient restaurees en local (repli
    `DefaultDomain`, desormais `localmux`).
  - entrees sur le domaine integre `local` : reecrites vers `localmux` par
    `migrate_local_to_mux`, **recursivement** (le champ `domain` existe au
    niveau du workspace ET de chaque pane, a n'importe quelle profondeur de
    l'arbre de layout). Rien ne doit rester sur un domaine qui ne persiste pas.
- **Le registre ne contient jamais `local`** : la capture passe par
  `domains.persisted` (`capture_pane`, `snapshot_domain`), qui reecrit `local`
  en `localmux` — un workspace capture pendant une session de repli doit repartir
  dans le mux a la restauration. Attention a ne pas confondre avec
  `domains.pane_domain`, qui doit rester **fidele** au pane reel : c'est lui qui
  alimente la barre de statut et la comparaison de `adopt_domain_session`. Les
  reecrire tous les deux ferait croire a une session persistante inexistante.
- **Domaine de spawn explicite** (`workspace_domain_spawn`) : le `pane` passe au
  callback d'un `InputSelector` / `PromptInputLine` est le pane **d'overlay**
  (`TermWizTerminalPane`), pas un pane du domaine vise. Tout spawn declenche
  depuis un tel callback doit donc nommer son domaine : sans lui, WezTerm resout
  `CurrentPaneDomain` vers `TermWizTerminalDomain` et refuse le spawn (`cannot
  spawn panes in a TermWizTerminalPane`, visible dans
  `~/.local/share/wezterm/wezterm-gui.exe-log-*.txt`) — le workspace s'ouvrait
  alors **sans aucun pane**. Le domaine passe est **celui du workspace** et non
  `DefaultDomain` : le defaut varie par fenetre depuis `ALT+SHIFT+D`, un
  workspace doit se restaurer la ou il a ete capture.
  Corollaire de la creation via `spawn_workspace_window` : un
  `SwitchToWorkspace` du depot ne porte plus jamais de `spawn`, et ne doit en
  porter que si sa cible est **deja vivante** — sur un workspace vide, une
  bascule sans `spawn` n'est pas neutre pour autant, elle retombe sur
  `SpawnCommand::default()`, donc sur `CurrentPaneDomain`. Ne pas regresser.

## Documentation

- Mettre a jour `WEZTERM_SHORTCUTS.md` a chaque ajout, suppression ou modification de raccourci.
- Garder ce fichier centre sur l'usage quotidien.
- Garder `guidelines.md` centre sur les decisions de maintenance et les conventions du depot.

## Verification

**`wezterm show-keys` NE VALIDE RIEN.** Quand la config utilisateur echoue a se
charger, WezTerm retombe silencieusement sur sa configuration PAR DEFAUT :
`show-keys` affiche alors les raccourcis d'usine, sans le moindre message, avec
un code de sortie 0. Verifie le 2026-08-19 sur un module Lua a la syntaxe cassee
— la commande repondait la meme chose qu'avec une config saine. Toute une soiree
de « config OK » n'a rien prouve, et un fichier invalide est parti en commit.

Verifier une modification, dans cet ordre :

1. **Le Lua se charge-t-il ?** C'est `ls-fonts` qui fait remonter l'erreur :

   ```powershell
   wezterm --config-file "$env:USERPROFILE\.config\wezterm\wezterm.lua" ls-fonts 2>&1 |
     Select-String -Pattern 'runtime error|error loading|traceback'
   ```

   Aucune ligne = le module se charge. Sinon la sortie donne fichier, ligne et
   message.

2. **Est-ce bien NOTRE config qui est active ?** Chercher un marqueur qui
   n'existe pas dans la config par defaut — `EmitEvent` (nos `action_callback`)
   ou `LEADER` — dans la sortie de `show-keys`. Absent = repli sur le defaut,
   donc echec de chargement.

3. **Aucun identifiant orphelin ?**

   ```powershell
   python tools/check-lua-identifiers.py lua/workspaces.lua
   ```

   Lua ne signale un appel a une fonction inexistante qu'a l'EXECUTION, et
   souvent dans un `pcall` qui l'avale. Le 2026-08-19, trois pannes ont eu cette
   meme cause : un helper supprime avec le bloc qui l'entourait, ses appelants
   restes en place. `pane_cwd`, puis `cwd_key`, puis `BUILD_FLIGHT_SECONDS` —
   cette derniere faisait echouer TOUTE ouverture de workspace, sans une ligne de
   journal. Le controle prend deux secondes et les aurait toutes attrapees.

4. Redemarrer ou recharger WezTerm et tester les raccourcis modifies.
5. Controler le diff : `git diff --check`, `git status --short`.

**Ne jamais ecrire d'antislash echappe depuis un outil d'edition automatique.**
Deux modules ont ete casses le meme soir par un `\` reduit a `\` en cours de
route (`'^%a:[/\]'` invalide, puis une chaine `'exit
'` coupee en deux lignes).
Preferer des formes qui n'en contiennent aucun : normaliser les separateurs avec
`path:gsub(string.char(92), '/')` avant de filtrer, et composer les caracteres de
controle avec `string.char(13)` plutot que `
`.

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
- Fenetre maximisee au demarrage (`lua/options.lua`,
  `M.apply_startup_maximize`) : maximisee et NON plein ecran, la barre des
  taches Windows doit rester visible. Declencheur `update-status`, une fois par fenetre GUI. Les deux evenements
  « evidents » sont inutilisables ici : `gui-startup` inhibe par sa seule
  presence la creation de la fenetre par defaut (cf. section Domaines), et
  `gui-attached` NE SE DECLENCHE PAS — c'est pourtant l'evenement documente pour
  ce cas, mais il suppose un RATTACHEMENT a un domaine, et `default_domain` vise
  le domaine integre. Meme point d'accroche, pour les memes raisons, que le
  prechargement des domaines (`run_preload_once`).
- **Un `wezterm.on` protege par une version dans `wezterm.GLOBAL` ne se
  declenche jamais** (verifie le 2026-08-19 : le journal recevait « handler
  enregistre » mais jamais « handler appele » ; enregistrement inconditionnel =
  handler appele). La garde n'enregistre le handler qu'a la PREMIERE evaluation
  de la config, alors que seuls les handlers de l'evaluation courante sont
  vivants. Corollaire a verifier : le handler de bascule clair/sombre de
  `lua/options.lua` porte exactement cette garde
  (`DYNAMIC_COLOR_SCHEME_EVENT_VERSION`) et est donc probablement mort lui aussi.
  Le modele qui marche est celui de `lua/workspaces.lua` : `wezterm.on` a chaque
  evaluation du module, et l'etat anti-repetition dans `wezterm.GLOBAL` sous une
  CLE SCALAIRE (`GLOBAL` ne conserve pas la mutation d'une table imbriquee).
- Diagnostic des handlers : journaliser dans `~/.wezterm-workspaces.log`
  (io.open, hors repo et hors `config_dir`), PAS via `wezterm.log_info` : le
  filtre de log par defaut du GUI ne fait pas ressortir la cible `config`, et
  les logs GUI (`~/.local/share/wezterm/wezterm-gui.exe-log-*.txt`) restent
  muets. Ils servent en revanche a reperer les erreurs de config transitoires :
  une ecriture en deux temps (`lua/*.lua` puis `wezterm.lua`) declenche un
  rechargement au milieu, `Configuration Error ... attempt to call a nil value`,
  et WezTerm garde alors la DERNIERE config valide — le test qui suit porte donc
  sur l'ancien code.
- `maximize()` de preference a `toggle_fullscreen()` : idempotent, donc
  insensible aux exemplaires de handler qui s'empilent. `toggle_fullscreen` n'a
  pas d'equivalent `set_fullscreen(true)`, il faudrait lire
  `get_dimensions().is_full_screen` avant chaque appel. `ALT+ENTER` (binding
  WezTerm par defaut, non redefini dans `lua/keys.lua`) reste la bascule plein
  ecran manuelle.
