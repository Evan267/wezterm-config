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

| Raccourci | Action | Description |
| :--- | :--- | :--- |
| `Leader` + `t` | **Nouveau Tab** | Crée un onglet dans le domaine par défaut |
| `Leader` + `v` | **Split Horizontal** | Divise le panneau horizontalement |
| `Leader` + `s` | **Split Vertical** | Divise le panneau verticalement |
| `Leader` + `w` | **Fermer Panneau** | Ferme le panneau actif (demande confirmation) |

---

## 🚀 Navigation et Redimensionnement
*Basé sur la fonction `split_nav`. Généralement intégré avec la navigation Vim si configuré.*

| Action | Direction | Touche |
| :--- | :--- | :--- |
| **Move** | Gauche / Bas / Haut / Droite | `CTRL` + `h` / `j` / `k` / `l` |
| **Resize** | Gauche / Bas / Haut / Droite | `META` + `h` / `j` / `k` / `l` |

---

## 🧭 Workspaces

Les commandes de workspace utilisent uniquement `ALT` comme modificateur. Les variantes `Leader` ont ete retirees.

| Raccourci             | Action                          | Description                                                                                                          |
| :-------------------- | :------------------------------ | :------------------------------------------------------------------------------------------------------------------- |
| `ALT` + `n`           | **Nouveau Workspace**           | Demande un nom puis bascule vers ce workspace non enregistre                                                         |
| `ALT` + `t`           | **Renommer Tab**                | Demande un nom pour le tab actif puis enregistre le workspace courant                                                |
| `ALT` + `r`           | **Enregistrer Workspace**       | Enregistre ou met a jour le workspace actif                                                                          |
| `ALT` + `o`           | **Ouvrir Workspace ici**        | Affiche les workspaces enregistres et ouvre la selection dans la fenetre courante                                    |
| `ALT` + `SHIFT` + `o` | **Ouvrir Workspace en fenetre** | Focalise la fenetre existante si le workspace est deja ouvert; sinon restaure la selection dans une nouvelle fenetre |
| `ALT` + `SHIFT` + `r` | **Tout restaurer**              | Restaure tous les workspaces actifs, chacun dans sa fenetre (workspaces deja ouverts ignores). A utiliser apres un redemarrage du mux-server de vibe |
| `ALT` + `d`           | **Supprimer Workspace**         | Affiche les workspaces enregistres (actifs et archives) et supprime la selection du registre                        |
| `ALT` + `a`           | **Archiver Workspace**          | Liste les workspaces actifs et archive la selection : masquee de `ALT+o` et du cycle, mais conservee dans le registre |
| `ALT` + `u`           | **Desarchiver Workspace**       | Liste les workspaces archives et reactive la selection (redevient visible dans `ALT+o` et le cycle)                 |
| `ALT` + `SHIFT` + `q` | **Quitter WezTerm**             | Ferme toute l'application WezTerm, avec toutes les fenetres, tabs et panes                                           |
| `ALT` + `←`           | **Workspace precedent**         | Bascule vers le workspace enregistre precedent                                                                       |
| `ALT` + `→`           | **Workspace suivant**           | Bascule vers le workspace enregistre suivant                                                                         |

---

## 🛠️ Notes de Configuration
* **Domaine** : Les splits utilisent `CurrentPaneDomain` pour conserver le répertoire de travail actuel.
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
