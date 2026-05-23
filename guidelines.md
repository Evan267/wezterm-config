# Guidelines du projet

## Vue d'ensemble

Ce depot contient une configuration WezTerm modulaire en Lua. Le point d'entree est `wezterm.lua`, qui construit l'objet `config`, applique les plugins, charge les modules locaux, puis retourne la configuration a WezTerm.

Structure actuelle :

- `wezterm.lua` : point d'entree de la configuration.
- `lua/options.lua` : options visuelles et comportementales de base.
- `lua/keys.lua` : raccourcis clavier personnalises et navigation de panneaux.
- `WEZTERM_SHORTCUTS.md` : aide-memoire utilisateur des raccourcis.

## Etat actuel

La configuration active charge actuellement :

- `bar.wezterm` pour la barre WezTerm.
- `wezterm-quota-limit` pour la gestion de quota.
- `lua/options.lua` pour les options generales.
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
