# ⌨️ Aide-mémoire WezTerm

Ce document recense les raccourcis clavier personnalisés pour ma configuration WezTerm, incluant la gestion des panneaux (splits) et des workspaces.

---

## 🔑 Touche Leader
Le **Leader Key** est le préfixe nécessaire pour les commandes système.
* **Combinaison** : `CTRL` + `b`
* **Délai d'attente** : 1000ms (1 seconde)

---

## 🪟 Gestion des Onglets et Panneaux
*Ces commandes nécessitent d'appuyer sur le **Leader Key** juste avant.*

| Raccourci      | Action                  | Description                                                                        |
| :------------- | :---------------------- | :--------------------------------------------------------------------------------- |
| `Leader` + `t` | **Nouveau Tab**         | Crée un onglet dans le domaine par défaut                                          |
| `Leader` + `v` | **Split Horizontal**    | Divise le panneau horizontalement                                                  |
| `Leader` + `s` | **Split Vertical**      | Divise le panneau verticalement                                                    |
| `Leader` + `w` | **Fermer Panneau**      | Ferme le panneau actif (demande confirmation)                                      |
| `Leader` + `W` | **Fermer Onglet**       | Ferme l'onglet actif et tous ses panneaux (demande confirmation)                   |
| `Leader` + `m` | **Debloquer la souris** | Reinitialise le suivi souris/focus reste bloque (souris = frappe clavier parasite) |

---

## 🚀 Navigation et Redimensionnement
*Basé sur la fonction `split_nav`. Généralement intégré avec la navigation Vim si configuré.*

| Action | Direction | Touche |
| :--- | :--- | :--- |
| **Move** | Gauche / Bas / Haut / Droite | `CTRL` + `h` / `j` / `k` / `l` |
| **Resize** | Gauche / Bas / Haut / Droite | `META` + `h` / `j` / `k` / `l` |

---

## 🖥️ Local ou distant

WezTerm peut faire tourner les panes sur **ce PC** (domaine `localmux`) ou sur le
**serveur distant** `vibe` (domaine mux TLS). Les deux cohabitent : un workspace
local et un workspace distant peuvent etre ouverts en meme temps.

Dans les deux cas les panes tournent dans un **`wezterm-mux-server`**, pas dans
la fenetre : ils **survivent a la fermeture** (ou au crash) de WezTerm, et le
relancer les retrouve tels quels, processus vivants et scrollback compris. En
local, le serveur est demarre automatiquement au besoin ; il meurt en revanche
avec la session Windows (deconnexion, reboot) — apres un reboot, la reprise
passe par `ALT` + `SHIFT` + `r` (rejeu depuis `workspaces.json`).

* **Au demarrage** : WezTerm s'ouvre sur le domaine **local integre**, sans
  solliciter le moindre serveur mux. Aucune question n'est posee, et l'ouverture
  ne peut donc pas echouer parce qu'un serveur ne repond pas. Les panes de ce
  premier workspace (`default`) vivent dans la fenetre et meurent avec elle.
* **Les connexions sont prechargees** : une seconde apres l'ouverture, WezTerm
  rattache les serveurs dont vos workspaces actifs ont besoin, pour que leurs
  sessions soient deja la quand vous basculez dessus. Un serveur qui ne repond
  pas est simplement ignore (teste en 800 ms max) : l'ouverture n'attend jamais
  apres lui.
* **Le serveur se choisit a la CREATION d'un workspace** (`ALT` + `n`) : `Local`
  le fait vivre dans le `wezterm-mux-server` de ce PC, `vibe` sur le serveur
  distant. Dans les deux cas ses panes survivent a la fermeture de WezTerm. Le
  domaine est ensuite fige dans `workspaces.json` : rouvrir le workspace le
  ramene toujours au meme endroit, sans rien demander. `ALT` + `SHIFT` + `d`
  change le domaine par defaut de la fenetre courante.
* **La disposition s'enregistre a chaque changement**, et non plus toutes les
  60 s : un split, un nouvel onglet, un renommage (`ALT` + `t`), une fermeture de
  panneau ou d'onglet, un redimensionnement, l'ouverture d'un workspace. Rien
  d'autre n'ecrit. Un redimensionnement n'est capture qu'une fois le geste
  TERMINE : maintenir `META` + `h`/`l` ou trainer le bord d'une fenetre emet des
  dizaines d'evenements, il n'en resulte qu'une seule ecriture. Un `cd` seul, en
  revanche, n'est pas enregistre sur le moment ; il le sera a la prochaine action.
* **Une seule fenetre visible a la fois par workspace** : WezTerm n'affiche que
  les fenetres du workspace **actif**. Une fenetre d'un autre workspace n'est pas
  fermee, juste masquee, et revient quand vous rebasculez dessus. Si vous voyez
  deux fenetres a l'ouverture, ce sont deux fenetres du meme workspace — souvent
  les deux `default`, celle de votre mux local et celle de vibe. Fermer celle qui
  ne sert pas suffit.
* **Indicateur** : la barre de statut affiche `WS <workspace> [<domaine>]`. Le
  domaine est celui du **pane actif** — c'est la machine ou tourne ce que vous
  avez sous les yeux.
* **Raccourci `ALT` + `SHIFT` + `d`** : change le domaine par defaut de la
  fenetre courante (localmux ↔ vibe). N'affecte que les spawns sans contexte ; les
  workspaces enregistres gardent le domaine fige dans `workspaces.json`.
* **Domaine memorise par workspace** : `ALT` + `n` demande le nom **puis** le
  domaine. Le domaine est enregistre dans `workspaces.json` et rejoue a la
  restauration, quel que soit le domaine de la fenetre depuis laquelle on ouvre.
  Les listes (`ALT` + `o`, `ALT` + `d`, `ALT` + `a`, `ALT` + `u`) affichent
  `nom  [domaine]`, filtrable au clavier (taper `vibe` ou `localmux`).

---

## 🧭 Workspaces

Les commandes de workspace utilisent uniquement `ALT` comme modificateur. Les variantes `Leader` ont ete retirees.

| Raccourci             | Action                          | Description                                                                                                                                          |
| :-------------------- | :------------------------------ | :--------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ALT` + `n`           | **Nouveau Workspace**           | Demande un nom puis un domaine (localmux / vibe), et bascule vers ce workspace non enregistre                                                         |
| `ALT` + `t`           | **Renommer Tab**                | Demande un nom pour le tab actif puis enregistre le workspace courant                                                                                |
| `ALT` + `r`           | **Enregistrer Workspace**       | Enregistre ou met a jour le workspace actif                                                                                                          |
| `ALT` + `o`           | **Ouvrir Workspace ici**        | Affiche les workspaces enregistres et ouvre la selection dans la fenetre courante                                                                    |
| `ALT` + `SHIFT` + `r` | **Tout restaurer**              | Restaure tous les workspaces actifs, chacun dans sa fenetre (workspaces deja ouverts ignores). A utiliser apres un redemarrage d'un mux-server (vibe, ou le mux local apres un reboot) |
| `ALT` + `d`           | **Supprimer Workspace**         | Affiche les workspaces enregistres (actifs et archives) et supprime la selection du registre                                                         |
| `ALT` + `a`           | **Archiver Workspace**          | Liste les workspaces actifs et archive la selection : masquee de `ALT+o` et du cycle, conservee dans le registre, **et sa session vivante est fermee** (depart vers le workspace suivant si c'est celui ou l'on se trouve) |
| `ALT` + `u`           | **Desarchiver Workspace**       | Liste les workspaces archives et reactive la selection : redevient visible dans `ALT+o` et le cycle, et se rouvre depuis son snapshot, sa session ayant ete fermee a l'archivage |
| `ALT` + `SHIFT` + `d` | **Changer de domaine**          | Bascule le domaine par defaut de la fenetre courante entre `localmux` (ce PC) et `vibe` (serveur distant)                                            |
| `ALT` + `SHIFT` + `q` | **Quitter WezTerm**             | Ferme toute l'application WezTerm, avec toutes les fenetres, tabs et panes                                                                           |
| `ALT` + `←`           | **Workspace precedent**         | Bascule vers le workspace enregistre precedent                                                                                                       |
| `ALT` + `→`           | **Workspace suivant**           | Bascule vers le workspace enregistre suivant                                                                                                         |

---

## 🛠️ Notes de Configuration
* **Domaine** : Les splits (`Leader` + `v`/`s`) et les nouveaux tabs (`Leader` + `t`) utilisent `CurrentPaneDomain` : ils restent sur la machine du pane courant, pas sur le domaine par defaut de la fenetre. Un tab ouvert dans un workspace distant reste donc distant, meme si la fenetre est locale par defaut.
* **Shell** : Sous Windows, les panes **locaux** ouvrent PowerShell directement (`pwsh.exe` s'il est installe, sinon `powershell.exe`) et non `cmd.exe`, qui est le defaut WezTerm. Forcable via la cle `SHELL_PROG` du `.env`. Le mux local lisant la meme config, il applique le meme shell ; en revanche il le fige a son demarrage, donc changer `SHELL_PROG` suppose de le redemarrer (`Stop-Process -Name wezterm-mux-server`, les panes vivants sont alors perdus). Les panes du domaine `vibe` dependent du `default_prog` configure sur le serveur, pas d'ici.
* **Domaine d'un workspace** : Stocke dans `workspaces.json` (champ `domain`, par workspace et par pane). Il est capture a l'enregistrement et rejoue a la restauration. Deux migrations automatiques au chargement : les entrees creees avant la gestion multi-domaines passent a `vibe` (elles ne pouvaient venir que de la), et celles enregistrees sur l'ancien domaine local non persistant passent a `localmux`. Un workspace de ce PC est donc **toujours** restaure dans le mux local.
* **Domaine injoignable** : Si `vibe` est inaccessible (VPN coupe, serveur eteint), ouvrir un workspace distant affiche `Domaine vibe injoignable` et ne casse rien ; `ALT` + `SHIFT` + `r` restaure quand meme tous les workspaces **locaux** et compte les autres dans `domaine injoignable`.
* **Registre** : Les workspaces sauvegardes sont stockes dans `workspaces.json` a la racine de cette configuration.
* **Sortie** : `exit_behavior = 'Close'` ferme les panes des que leur process se termine, meme si le dernier code de sortie n'est pas zero.
* **Sauvegarde workspace** : La sauvegarde conserve les tabs, les panes/splits, le repertoire courant de chaque pane et la derniere commande executee.
* **Titres de tabs** : Les titres definis avec `ALT` + `t` sont stockes dans `workspaces.json` et reappliques lors de la restauration.
* **Restauration workspace** : Si le workspace est deja ouvert, la config le rejoint sans relancer les commandes. Sinon, elle recree les tabs/panes, retourne dans les repertoires sauvegardes et relance la derniere commande quand elle est disponible. Certaines commandes ne sont jamais rejouees (triviales ou dangereuses : `cd`, `clear`, `ls`, `exit`, `wezterm-mux-server`, …).
* **Auto-sauvegarde** : Toutes les 60 s, les workspaces **deja enregistres** sont rafraichis depuis leurs fenetres vivantes (cwd et commandes recents), sans en creer de nouveaux ni ecraser une sauvegarde par un etat vide. Objectif : que `ALT` + `Shift` + `r` reparte d'un etat recent apres un redemarrage du mux-server.
* **Perte au redemarrage du mux-server** : Les panes tournent comme process enfants d'un `wezterm-mux-server` — celui de vibe, ou le mux local, qui meurt avec la session Windows (deconnexion, reboot). S'il redemarre, ils meurent avec lui (le mux-server ne persiste pas sur disque). `ALT` + `Shift` + `r` relance alors tous les workspaces actifs depuis `workspaces.json`.
* **Suppression workspace** : La suppression retire uniquement l'entree du registre; elle ne ferme pas un workspace deja ouvert.
* **Archivage workspace** : L'archivage (`ALT` + `a`) retire le workspace des listes du quotidien (`ALT` + `o` et cycle `ALT` + `←`/`→`) sans rien supprimer du registre : tabs, panes et cwd restent intacts dans `workspaces.json` (marqueur `archived_at`), et `ALT` + `u` le reactive.
  En revanche il **ferme la session vivante** : un snapshot est pris, puis `exit` est envoye au shell de chaque pane. Sans cela les panes tournaient indefiniment sur leur mux-server sans que personne ne les rattache jamais — celui de vibe est relance par tache planifiee, donc ses fenetres survivent aux deconnexions comme aux redemarrages du poste. Les panes ou tourne autre chose qu'un shell sont laisses en place et annonces dans la notification.
  Si on archive le workspace **courant**, on est deplace vers le suivant avant la fermeture, pour ne pas fermer ses panes sous ses propres pieds. Desarchiver puis rouvrir reconstruit alors le workspace depuis son snapshot.
  Un workspace archive reste supprimable via `ALT` + `d` (marque « (archive) » dans la liste).
* **Suivi shell** : Le fichier `shell/bash-workspace-tracker.bash` publie le repertoire courant et la derniere commande a WezTerm via des user vars.
* **Deblocage souris** (`Leader` + `m`) : Quand une appli TUI (nvim, htop, tmux, `less`…) meurt sans desactiver le suivi souris, le pane reste en mode « any-event » et chaque deplacement de souris arrive comme des octets parasites (`<35;…M`) sur la ligne de commande. C'est un etat **par pane** : seul le pane fautif est touche, les autres restent sains. Le raccourci envoie `Ctrl-U` (purge la ligne des parasites deja tapes) puis un `printf` des sequences DECRST (`\e[?1000l`, `?1002l`, `?1003l`, `?1004l`, `?1006l`…) suivi de Entree. On passe par le shell (`SendString`/`send_text`) et non par `pane:inject_output` : ce dernier ne fonctionne **que sur les panes locaux, pas sur les panes mux** (cf. doc WezTerm), or nos panes tournent sur le mux-server de vibe. La sortie du `printf` repasse par le parseur du terminal cote serveur et remet les modes a zero. A utiliser au prompt shell (sans effet si une appli est encore en train de tourner et de reactiver le suivi). Equivalent manuel : la commande `reset`.
