# ⌨️ Aide-mémoire WezTerm

Ce document recense les raccourcis clavier personnalisés pour ma configuration WezTerm, incluant la gestion des panneaux (splits) et la persistance des sessions via le plugin `Resurrect`.

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
| **Move** | Gauche / Bas / Haut / Droite | `h` / `j` / `k` / `l` |
| **Resize** | Gauche / Bas / Haut / Droite | *(Selon config `split_nav`)* |

---

## 💾 Sauvegarde et Restauration (Resurrect)
*Ces raccourcis utilisent principalement la touche **ALT**.*

| Raccourci | Action | Portée | Description |
| :--- | :--- | :--- | :--- |
| `ALT` + `w` | **Save State** | Workspace | Sauvegarde l'état complet de l'espace de travail |
| `ALT` + `W` (Maj) | **Save Window** | Window | Sauvegarde l'état de la fenêtre actuelle |
| `ALT` + `T` (Maj) | **Save Tab** | Tab | Sauvegarde l'état de l'onglet actuel |
| `ALT` + `s` | **Super Save** | Global | Sauvegarde Workspace + Window en un coup |
| `ALT` + `r` | **Restore** | Fuzzy Finder | Ouvre le menu de restauration (Workspace/Window/Tab) |

### 🔍 Détails du menu de restauration (`ALT + r`)
Le script analyse automatiquement le type de sauvegarde :
1.  **Workspace** : Restaure l'ensemble de l'espace de travail de manière relative.
2.  **Window** : Restaure une fenêtre spécifique dans la fenêtre actuelle.
3.  **Tab** : Restaure un onglet spécifique dans l'onglet actuel.

---

## 🛠️ Notes de Configuration
* **Domaine** : Les splits utilisent `CurrentPaneDomain` pour conserver le répertoire de travail actuel.
* **Restauration** : La restauration inclut le texte (`restore_text = true`) et les processus pour les panneaux.
