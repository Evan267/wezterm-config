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

WezTerm peut faire tourner les panes sur **ce PC** (domaine `local`) ou sur le
**serveur distant** `vibe` (domaine mux TLS). Les deux cohabitent : un workspace
local et un workspace distant peuvent etre ouverts en meme temps.

* **Au demarrage** : un selecteur « Ou travailler ? » s'affiche dans la premiere
  fenetre. `Local` garde la session sur ce PC ; `vibe` rattache le mux-server
  distant (les workspaces deja vivants la-bas sont recuperes tels quels, sinon
  une session distante est demarree). La premiere fenetre est **toujours** locale
  au depart : l'ouverture de WezTerm ne depend jamais de la joignabilite du
  serveur (VPN coupe, machine eteinte).
* **Indicateur** : la barre de statut affiche `WS <workspace> [<domaine>]`. Le
  domaine est celui du **pane actif** — c'est la machine ou tourne ce que vous
  avez sous les yeux.
* **Raccourci `ALT` + `SHIFT` + `d`** : change le domaine par defaut de la
  fenetre courante (local ↔ vibe). N'affecte que les spawns sans contexte ; les
  workspaces enregistres gardent le domaine fige dans `workspaces.json`.
* **Domaine memorise par workspace** : `ALT` + `n` demande le nom **puis** le
  domaine. Le domaine est enregistre dans `workspaces.json` et rejoue a la
  restauration, quel que soit le domaine de la fenetre depuis laquelle on ouvre.
  Les listes (`ALT` + `o`, `ALT` + `d`, `ALT` + `a`, `ALT` + `u`) affichent
  `nom  [domaine]`, filtrable au clavier (taper `vibe` ou `local`).

---

## 🧭 Workspaces

Les commandes de workspace utilisent uniquement `ALT` comme modificateur. Les variantes `Leader` ont ete retirees.

| Raccourci             | Action                          | Description                                                                                                                                          |
| :-------------------- | :------------------------------ | :--------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ALT` + `n`           | **Nouveau Workspace**           | Demande un nom puis un domaine (local / vibe), et bascule vers ce workspace non enregistre                                                            |
| `ALT` + `t`           | **Renommer Tab**                | Demande un nom pour le tab actif puis enregistre le workspace courant                                                                                |
| `ALT` + `r`           | **Enregistrer Workspace**       | Enregistre ou met a jour le workspace actif                                                                                                          |
| `ALT` + `o`           | **Ouvrir Workspace ici**        | Affiche les workspaces enregistres et ouvre la selection dans la fenetre courante                                                                    |
| `ALT` + `SHIFT` + `o` | **Ouvrir Workspace en fenetre** | Focalise la fenetre existante si le workspace est deja ouvert; sinon restaure la selection dans une nouvelle fenetre                                 |
| `ALT` + `SHIFT` + `r` | **Tout restaurer**              | Restaure tous les workspaces actifs, chacun dans sa fenetre (workspaces deja ouverts ignores). A utiliser apres un redemarrage du mux-server de vibe |
| `ALT` + `d`           | **Supprimer Workspace**         | Affiche les workspaces enregistres (actifs et archives) et supprime la selection du registre                                                         |
| `ALT` + `a`           | **Archiver Workspace**          | Liste les workspaces actifs et archive la selection : masquee de `ALT+o` et du cycle, mais conservee dans le registre                                |
| `ALT` + `u`           | **Desarchiver Workspace**       | Liste les workspaces archives et reactive la selection (redevient visible dans `ALT+o` et le cycle)                                                  |
| `ALT` + `SHIFT` + `d` | **Changer de domaine**          | Bascule le domaine par defaut de la fenetre courante entre `local` (ce PC) et `vibe` (serveur distant)                                               |
| `ALT` + `SHIFT` + `q` | **Quitter WezTerm**             | Ferme toute l'application WezTerm, avec toutes les fenetres, tabs et panes                                                                           |
| `ALT` + `←`           | **Workspace precedent**         | Bascule vers le workspace enregistre precedent                                                                                                       |
| `ALT` + `→`           | **Workspace suivant**           | Bascule vers le workspace enregistre suivant                                                                                                         |

---

## 🛠️ Notes de Configuration
* **Domaine** : Les splits (`Leader` + `v`/`s`) et les nouveaux tabs (`Leader` + `t`) utilisent `CurrentPaneDomain` : ils restent sur la machine du pane courant, pas sur le domaine par defaut de la fenetre. Un tab ouvert dans un workspace distant reste donc distant, meme si la fenetre est locale par defaut.
* **Shell** : Sous Windows, les panes **locaux** ouvrent PowerShell directement (`pwsh.exe` s'il est installe, sinon `powershell.exe`) et non `cmd.exe`, qui est le defaut WezTerm. Forcable via la cle `SHELL_PROG` du `.env`. Les panes du domaine `vibe` dependent du `default_prog` configure sur le serveur, pas d'ici.
* **Domaine d'un workspace** : Stocke dans `workspaces.json` (champ `domain`, par workspace et par pane). Il est capture a l'enregistrement et rejoue a la restauration. Les entrees creees avant la gestion multi-domaines sont migrees automatiquement vers `vibe` au premier chargement (elles ne pouvaient venir que de la).
* **Domaine injoignable** : Si `vibe` est inaccessible (VPN coupe, serveur eteint), ouvrir un workspace distant affiche `Domaine vibe injoignable` et ne casse rien ; `ALT` + `SHIFT` + `r` restaure quand meme tous les workspaces **locaux** et compte les autres dans `domaine injoignable`.
* **Registre** : Les workspaces sauvegardes sont stockes dans `workspaces.json` a la racine de cette configuration.
* **Sortie** : `exit_behavior = 'Close'` ferme les panes des que leur process se termine, meme si le dernier code de sortie n'est pas zero.
* **Sauvegarde workspace** : La sauvegarde conserve les tabs, les panes/splits, le repertoire courant de chaque pane et la derniere commande executee.
* **Titres de tabs** : Les titres definis avec `ALT` + `t` sont stockes dans `workspaces.json` et reappliques lors de la restauration.
* **Restauration workspace** : Si le workspace est deja ouvert, la config le rejoint sans relancer les commandes. Sinon, elle recree les tabs/panes, retourne dans les repertoires sauvegardes et relance la derniere commande quand elle est disponible. Certaines commandes ne sont jamais rejouees (triviales ou dangereuses : `cd`, `clear`, `ls`, `exit`, `wezterm-mux-server`, …).
* **Auto-sauvegarde** : Toutes les 60 s, les workspaces **deja enregistres** sont rafraichis depuis leurs fenetres vivantes (cwd et commandes recents), sans en creer de nouveaux ni ecraser une sauvegarde par un etat vide. Objectif : que `ALT` + `Shift` + `r` reparte d'un etat recent apres un redemarrage du mux-server.
* **Perte au redemarrage du mux-server** : Les panes tournent comme process enfants du `wezterm-mux-server` de vibe ; s'il redemarre, ils meurent avec lui (le mux-server ne persiste pas sur disque). `ALT` + `Shift` + `r` relance alors tous les workspaces actifs depuis `workspaces.json`.
* **Suppression workspace** : La suppression retire uniquement l'entree du registre; elle ne ferme pas un workspace deja ouvert.
* **Archivage workspace** : L'archivage (`ALT` + `a`) retire le workspace des listes du quotidien (`ALT` + `o` et cycle `ALT` + `←`/`→`) sans rien supprimer : tabs, panes et cwd restent intacts dans `workspaces.json` (marqueur `archived_at`). `ALT` + `u` le reactive. L'operation est reversible autant de fois que voulu et n'affecte pas une session deja ouverte. Un workspace archive reste supprimable via `ALT` + `d` (marque « (archive) » dans la liste).
* **Suivi shell** : Le fichier `shell/bash-workspace-tracker.bash` publie le repertoire courant et la derniere commande a WezTerm via des user vars.
* **Deblocage souris** (`Leader` + `m`) : Quand une appli TUI (nvim, htop, tmux, `less`…) meurt sans desactiver le suivi souris, le pane reste en mode « any-event » et chaque deplacement de souris arrive comme des octets parasites (`<35;…M`) sur la ligne de commande. C'est un etat **par pane** : seul le pane fautif est touche, les autres restent sains. Le raccourci envoie `Ctrl-U` (purge la ligne des parasites deja tapes) puis un `printf` des sequences DECRST (`\e[?1000l`, `?1002l`, `?1003l`, `?1004l`, `?1006l`…) suivi de Entree. On passe par le shell (`SendString`/`send_text`) et non par `pane:inject_output` : ce dernier ne fonctionne **que sur les panes locaux, pas sur les panes mux** (cf. doc WezTerm), or nos panes tournent sur le mux-server de vibe. La sortie du `printf` repasse par le parseur du terminal cote serveur et remet les modes a zero. A utiliser au prompt shell (sans effet si une appli est encore en train de tourner et de reactiver le suivi). Equivalent manuel : la commande `reset`.
