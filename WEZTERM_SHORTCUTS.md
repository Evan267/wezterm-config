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

| Raccourci | Action | Description |
| :--- | :--- | :--- |
| `ALT` + `n` | **Nouveau Workspace** | Demande un nom puis bascule vers ce workspace non enregistre |
| `ALT` + `r` | **Enregistrer Workspace** | Enregistre ou met a jour le workspace actif |
| `ALT` + `o` | **Ouvrir Workspace ici** | Affiche les workspaces enregistres et ouvre la selection dans la fenetre courante |
| `ALT` + `SHIFT` + `o` | **Ouvrir Workspace en fenetre** | Focalise la fenetre existante si le workspace est deja ouvert; sinon restaure la selection dans une nouvelle fenetre |
| `ALT` + `d` | **Supprimer Workspace** | Affiche les workspaces enregistres et supprime la selection du registre |
| `ALT` + `←` | **Workspace precedent** | Bascule vers le workspace enregistre precedent |
| `ALT` + `→` | **Workspace suivant** | Bascule vers le workspace enregistre suivant |

---

## 🛠️ Notes de Configuration
* **Domaine** : Les splits utilisent `CurrentPaneDomain` pour conserver le répertoire de travail actuel.
* **Registre** : Les workspaces sauvegardes sont stockes dans `workspaces.json` a la racine de cette configuration.
* **Sauvegarde workspace** : La sauvegarde conserve les tabs, les panes/splits, le repertoire courant de chaque pane et la derniere commande executee.
* **Restauration workspace** : Si le workspace est deja ouvert, la config le rejoint sans relancer les commandes. Sinon, elle recree les tabs/panes, retourne dans les repertoires sauvegardes et relance la derniere commande quand elle est disponible.
* **Suppression workspace** : La suppression retire uniquement l'entree du registre; elle ne ferme pas un workspace deja ouvert.
* **Suivi shell** : Le fichier `shell/bash-workspace-tracker.bash` publie le repertoire courant et la derniere commande a WezTerm via des user vars.
