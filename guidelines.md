# Guidelines du projet

## Vue d'ensemble

Ce depot contient une configuration WezTerm modulaire en Lua. Le point d'entree est `wezterm.lua`, qui construit l'objet `config`, applique les plugins, charge les modules locaux, puis retourne la configuration a WezTerm.

Structure actuelle :

- `wezterm.lua` : point d'entree de la configuration.
- `lua/env.lua` : chargement des variables depuis `.env` (avec defauts internes).
- `lua/options.lua` : options visuelles et comportementales de base.
- `lua/status.lua` : barre native WezTerm et titres d'onglets.
- `lua/keys.lua` : raccourcis clavier personnalises et navigation de panneaux.
- `.env` / `.env.example` : variables par-machine (domaine mux). `.env` est
  gitignore ; `.env.example` est le modele versionne. Voir `VIBE_TLS_SETUP.md`.
- `WEZTERM_SHORTCUTS.md` : aide-memoire utilisateur des raccourcis.

## Etat actuel

La configuration active charge actuellement :

- `lua/options.lua` pour les options generales.
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
