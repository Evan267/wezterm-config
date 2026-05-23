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

| Raccourci | Action | Description |
| :--- | :--- | :--- |
| `ALT` + `n` | **Nouveau Workspace** | Demande un nom puis bascule vers ce workspace |

---

## 🛠️ Notes de Configuration
* **Domaine** : Les splits utilisent `CurrentPaneDomain` pour conserver le répertoire de travail actuel.
