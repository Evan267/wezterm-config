# Audit de la gestion des workspaces

Audit du sous-système de persistance/restauration des workspaces WezTerm de ce
dépôt (poste client → mux-server `vibe`). Périmètre : `lua/workspaces.lua`,
son câblage dans `lua/keys.lua`, le tracker `shell/pwsh-workspace-tracker.ps1`,
le registre `workspaces.json` et la doc associée.

Date : 2026-07-07.

---

## 1. Architecture actuelle

```
lua/keys.lua ──require──▶ lua/workspaces.lua ──lit/écrit──▶ workspaces.json
                                │                            (config_dir, gitignore)
                                ├──append──▶ workspaces-debug.log (gitignore)
                                └──set_right_status──▶ notifications (barre WezTerm)

shell/pwsh-workspace-tracker.ps1 (sourcé dans $PROFILE de vibe)
   └──OSC 7 + user vars──▶ WEZTERM_WORKSPACE_CWD / WEZTERM_WORKSPACE_LAST_COMMAND
```

- **Capture** (`save_current`) : parcourt les tabs/panes de la fenêtre mux,
  relève cwd (user var → titre → `get_current_working_dir`), argv, titre,
  dernière commande, géométrie des panes, puis `upsert` dans le registre.
- **Restauration** (`restore_workspace`) : trois chemins — rejoindre un
  workspace déjà vivant (`SwitchToWorkspace`), reconstruire dans la fenêtre
  courante, ou dans une nouvelle fenêtre. La géométrie des splits est
  reconstruite par découpe récursive (`build_layout` / `apply_layout`).
- **Raccourcis** : `ALT+n/r/o/O/d`, `ALT+t` (renommer tab), `ALT+←/→` (cycle).

L'ensemble est robuste dans les grandes lignes (pcall systématique autour des
API mux, notifications d'erreur, gestion des cas « legacy »). Les points
ci-dessous sont classés par priorité.

---

## 2. Bugs et robustesse

### 🔴 B1 — Un pane éphémère fait échouer la sauvegarde de TOUT le workspace

Reproduit dans `workspaces-debug.log` :

```
capture failed: pane id 38 not found in mux
  [C]: in method 'get_current_working_dir'
  lua/workspaces.lua:220: in upvalue 'current_working_dir'
  lua/workspaces.lua:683: ...
```

`current_working_dir` (l. 219) appelle `pane:get_current_working_dir()` **sans
`pcall`**, contrairement aux autres accès pane (`pane_process_argv`,
`pane_title`, `pane_user_vars` sont tous protégés). Si un pane disparaît entre
l'énumération et la lecture du cwd (course classique : fermeture d'un pane,
commande qui se termine avec `exit_behavior='Close'`), l'exception remonte
jusqu'au `pcall` global de `save_current` et **abandonne la capture entière** :
aucun tab n'est enregistré, l'utilisateur perd sa sauvegarde.

**Correctif** : protéger `pane:get_current_working_dir()` par `pcall` dans
`current_working_dir`, et surtout isoler la capture de chaque pane dans un
`pcall` au sein de la boucle de `capture_current_window` (l. 644) — un pane mort
doit être ignoré, pas faire tomber les autres.

### 🟠 B2 — Rejeu de `last_command` non filtré (commandes triviales ou destructrices)

`pane_spawn` relance `last_command` via `powershell.exe -NoExit -Command <cmd>`.
Le seul filtrage est « vide » et « contient un saut de ligne ». Or le registre
contient aujourd'hui des `last_command` comme `exit`, `clear`, `ls`, `cd …`
(cf. `workspaces.json`). Conséquences au restore :

- `exit` : relance un shell qui tente immédiatement de sortir.
- `clear` / `ls` / `cc` : bruit inutile, mais surtout **écrase la vraie
  intention** (la dernière commande *utile* n'est plus celle capturée).

**Correctif** : maintenir une *denylist* de commandes non rejouables
(`exit`, `clear`, `cls`, `ls`, `ll`, `cd`, `pwd`, `logout`, …) et, idéalement,
ne mémoriser dans le tracker que les commandes « longues » (voir R3).

### 🟠 B3 — Noms de workspaces non normalisés (espaces parasites)

`workspaces.json` contient `"ia-image-detection-training-frontend "` (espace
final, hérité d'un renommage). Ni `save_current` ni `canonical_workspace_name`
ne font de `trim`. Résultat : entrées quasi-dupliquées, sélection floue peu
fiable, cycle `ALT+←/→` qui « saute » sur une entrée fantôme.

**Correctif** : `trim` systématique du nom à la saisie (`prompt_save_current`,
`prompt_new_workspace`) et dans `canonical_workspace_name`.

### 🟡 B4 — Écriture concurrente du registre (read-modify-write global)

`upsert_workspace` / `remove_workspace` relisent puis réécrivent **tout**
`workspaces.json` sans verrou. Deux fenêtres qui sauvegardent en même temps
(ou save pendant delete) : le dernier écrivain écrase l'autre. Risque faible en
mono-utilisateur, mais réel avec plusieurs fenêtres ouvertes sur le même mux.

**Correctif léger** : écriture atomique (fichier temporaire + `os.rename`) pour
au moins éviter un fichier tronqué/corrompu en cas d'interruption.

### 🟡 B5 — `snapshot_version` écrit mais jamais vérifié

`snapshot_version = 1` est écrit (l. 682) mais `load_registry` ne le lit jamais.
Aucune migration possible le jour où le format change : les vieilles entrées
seront mal interprétées silencieusement.

**Correctif** : contrôler `version` au chargement et prévoir un point de
migration (ou au minimum ignorer/avertir sur une version inconnue).

---

## 3. Cohérence de la restauration

### 🟡 C1 — Shell de rejeu codé en dur (`powershell.exe`)

`pane_spawn` relance toujours via `powershell.exe`, alors que la table
`shell_names` reconnaît `bash`, `fish`, `nu`, `zsh`, `sh`… Le commentaire assume
que vibe est toujours PowerShell — c'est vrai aujourd'hui, mais l'incohérence
(détecter N shells / n'en relancer qu'un) est un piège pour l'évolution. À
défaut de généraliser, documenter explicitement l'hypothèse « vibe = pwsh » à
côté de la table `shell_names`.

### 🟡 C2 — Le pane actif n'est pas refocalisé après restauration

La capture note `is_active` par pane, mais `apply_layout` recrée toujours en
partant du premier leaf et ne restaure pas le focus sur le pane qui était actif.
Petite gêne UX : après restore, le focus est arbitraire.

**Correctif** : après reconstruction, activer le pane dont le snapshot portait
`is_active = true`.

### 🟢 C3 — `M.spawn_tab(window, pane)` appelé avec un argument de trop

`lua/keys.lua:45` appelle `workspaces.spawn_tab(window, pane)` mais la signature
est `M.spawn_tab(window)`. Sans effet, mais à nettoyer pour éviter la confusion.

---

## 4. Maintenabilité et code mort

### 🟠 M1 — `live_workspace_name` : code mort

`live_workspace_name` (l. 197) n'est **jamais appelée**. Toute la machinerie de
noms suffixés « live HHMMSS » (`canonical_workspace_name` qui strip le suffixe,
`registered_workspaces` qui filtre les noms non canoniques) est un vestige d'une
conception antérieure. Aujourd'hui rien ne crée de nom « live », donc :

- `registered_workspaces` fait un filtrage qui ne filtre jamais rien ;
- `canonical_workspace_name` applique un `match` inutile à chaque appel.

**Correctif** : supprimer `live_workspace_name`, simplifier
`canonical_workspace_name` en simple `trim`, et remplacer `registered_workspaces`
par une simple copie — **sauf** si la réintroduction du mode « live » est
prévue, auquel cas le documenter dans `guidelines.md`.

### 🟡 M2 — `workspaces-debug.log` : journal permanent, append-only, non borné

Le fichier fait déjà **263 Ko** et grossit à chaque `save`/`restore`/`capture`
(`append_debug` est sur les chemins chauds). Aucune rotation ni cap. Le debug
est toujours actif, sans interrupteur.

**Correctif** : (a) passer le debug derrière un flag (`.env` :
`WORKSPACES_DEBUG=1`), désactivé par défaut ; (b) borner le fichier (rotation
simple : tronquer au-delà de N Ko au démarrage).

### 🟢 M3 — `pane_user_vars` appelé deux fois par pane à la capture

`capture_current_window` lit deux user vars via `pane_user_var`, qui appelle
`get_user_vars()` à chaque fois → deux appels FFI par pane. Récupérer la table
une seule fois par pane. Micro-optimisation, mais gratuite.

### 🟢 M4 — Deux handlers `update-status` séparés

`lua/status.lua` (statut gauche = nom du workspace) et `lua/workspaces.lua`
(statut droit = purge des notifications) enregistrent chacun un handler
`update-status`, tous deux à ~1 s. Fonctionnellement OK, mais deux effets de
bord globaux là où `guidelines.md` recommande de les éviter. Envisager de
centraliser l'orchestration `update-status`.

---

## 5. Documentation à corriger

### 🟠 D1 — Référence à un tracker bash inexistant

`WEZTERM_SHORTCUTS.md:62` et `shell/pwsh-workspace-tracker.ps1:3` citent
`shell/bash-workspace-tracker.bash`, **qui n'existe plus** (seul le tracker
PowerShell subsiste). Le dépôt étant la config du client Windows → vibe (pwsh),
la mention bash est trompeuse.

**Correctif** : remplacer par `shell/pwsh-workspace-tracker.ps1` dans les deux
fichiers.

### 🟢 D2 — `guidelines.md` silencieux sur le sous-système workspaces

`guidelines.md` liste `env/options/status/keys` mais pas `lua/workspaces.lua`
(le plus gros module, 1265 lignes) ni `shell/`. Ajouter une section décrivant le
contrat capture/restore et le rôle des user vars du tracker.

---

## 6. Plan d'action proposé (par ordre de valeur)

| Prio | Item | Effort | Gain |
| :--- | :--- | :--- | :--- |
| 1 | **B1** — pcall par pane à la capture | faible | supprime la perte de sauvegarde observée |
| 2 | **D1** — corriger la réf. tracker bash | trivial | doc juste (exigée par CLAUDE.md) |
| 3 | **M1** — retirer le code mort « live » | faible | −~40 lignes, logique plus lisible |
| 4 | **B3** — trim des noms | faible | fin des doublons fantômes |
| 5 | **B2** — denylist de rejeu | moyen | restore plus sûr et pertinent |
| 6 | **M2** — debug derrière flag + rotation | faible | fin de la croissance disque |
| 7 | **B4/B5** — écriture atomique + version | moyen | robustesse registre |
| 8 | **C1/C2** — hypothèse shell + refocus | moyen | fidélité de restauration |
| 9 | **M3/M4/C3/D2** — nettoyages divers | faible | qualité |

Les items 1–4 sont des corrections courtes et sans risque, à traiter en
priorité. Conformément à `CLAUDE.md`, toute correction de `lua/workspaces.lua`,
`lua/keys.lua` ou du tracker doit mettre à jour `WEZTERM_SHORTCUTS.md` /
`guidelines.md` **dans le même commit**.
