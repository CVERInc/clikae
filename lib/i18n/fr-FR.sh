# shellcheck shell=bash
# shellcheck disable=SC2034  # T_* are a string table consumed by the renderers.
# lib/i18n/fr-FR.sh — Français. Loaded OVER the en-US base by i18n_load, and must
# define every key lib/i18n/en-US.sh defines (tests/bats/i18n.bats enforces it,
# including printf placeholder parity). Same file contract as en-US.sh: one
# `T_KEY="value"` per line at column 0, %s/%d kept in en-US's order, %% for a
# literal percent.
#
# Typography: French convention puts a (fine non-breaking) space before : ? !
# — in this monospace TUI we use a REGULAR space before : ? ! consistently
# (NBSP would fight column math; omitting the space reads as English typo).
# Register: vous / dropped pronouns, matching Apple's French macOS strings.

T_LANG_NAME="Français"

# board
T_WORDMARK="clikae"                          # plain wordmark (the katakana bonus is ja-JP-only)
T_TAGLINE1="changez de compte sur n'importe quel CLI"
T_TAGLINE2="— changez de réservoir, gardez la flamme"
T_CONTINUE="Reprise"
T_RESUME_FOOTER="%d sessions au total · [R] pour tout voir / rechercher"
T_TANKS="Réservoirs"
T_SOLO_SECTION="Solo"
T_LANG_PICK="Langue de l'interface"
T_RESUME="reprise"
T_ENTER_RESUME="Enter : reprendre"
T_ALSO_AVAILABLE="Aussi disponibles"
T_NO_TANK_DEFAULT="aucun réservoir — ouvre par défaut"
T_AGY_NOTE="compte unique · connexion globale (un compte, tous les shells)"
T_AGY_BURN_NOTE="La connexion agy est globale (un seul compte à la fois, jamais deux en parallèle) — 'clikae burn agy <tank>' peut la faire basculer vers le réservoir suivant une fois à sec (transfert Keychain, sans OAuth), ou lancez-le en headless sur le compte actif avec 'agy -p'."
T_LAUNCH="lancer"
T_MORE="plus"
T_OVER_QUOTA="quota épuisé"
T_OVER_QUOTA_HINT="transférez la session vers le réservoir suivant :  clikae to"
# footer key hints
T_K_MOVE="déplacer"
T_K_OPEN="ouvrir"
T_K_RELAY="relais"
T_K_NEW="créer"
T_K_RENAME="renommer"
T_K_DELETE="supprimer"
T_K_SOLO="solo / quitter le solo (hors de la flotte — sans relais/burn/partage)"
T_K_MEMORY="mémoire (Soul) — partager / isoler le cerveau de ce réservoir"
T_MEM_TITLE="Mémoire (Soul)"
T_MEM_OPT_SHARE="partager dans un groupe…"
T_MEM_OPT_ISOLATE="isoler (mémoire à part)"
T_MEM_OPT_STATUS="état (voir le partage)"
T_MEM_SHARE_FOR="Partager la mémoire de"
T_MEM_GROUP_PROMPT="Nom du groupe : "
T_MEM_NOGROUP="Aucun nom de groupe — annulé."
T_K_QUIT="quitter"
T_K_FILTER="filtrer"
T_K_CLEANUP="nettoyer"
T_K_CLEAN="nettoyer les données de session — libérer de l'espace disque"
T_CLEAN_SECT_REDUNDANT="Doublons (sans risque)"
T_CLEAN_SECT_OLD="Inutilisé depuis plus de %s jours"
T_CLEAN_SECT_MIN="%s MB ou plus"
T_CLEAN_SECT_BIG="Gros mais récent — à vous de voir"
T_K_HELP="aide"
T_K_LANG="langue"
T_K_TOPBOTTOM="haut/bas"
T_K_JUMP="aller au N-ième"
T_K_REORDER="réordonner"
T_K_AUTO="autonomie"
T_K_INCOGNITO="incognito"
# welcome
T_NO_TANKS_YET="Aucun réservoir"
T_ENGINES_HERE="moteurs, ici :"
T_ENGINES_SUPPORTED="moteurs pris en charge"
T_NONE_DETECTED="(aucun détecté sur le PATH ici)"
T_FILL_FIRST="Remplissez votre premier réservoir :"
T_CURIOUS_DEMO="Curieux ?  clikae demo"
# resume submenu
T_RESUME_TITLE="Cette session — la suite ?"
T_RESUME_OPT_RESUME="Reprendre là où vous en étiez"
T_RESUME_OPT_SWITCH="Ouvrir ce réservoir à neuf (sans reprendre)"
T_RESUME_DRY_TITLE="%s est à sec — on continue ?"
T_RESUME_OPT_RELAY="Transférer cette session vers %s"
T_RESUME_OPT_FORCE="Reprendre %s quand même (la limite sera atteinte)"
T_RESUME_OPT_CARRY="Transférer cette session vers un autre réservoir"
T_RESUME_CARRY_PICK="Transférer %s — choisissez un réservoir pour continuer"
T_RESUME_WHICH_TANK="Reprendre sur quel réservoir ?"
T_UPDATE_AVAIL="Mise à jour disponible !"
T_UPDATE_NOTES="Notes de version :"
T_UPDATE_NOW="Mettre à jour maintenant (exécute \`%s\`)"
T_UPDATE_SHOW="Afficher la commande de mise à jour"
T_UPDATE_SKIP="Ignorer"
T_UPDATE_SKIP_VER="Ignorer jusqu'à la prochaine version"
T_UPDATE_DONE="Mis à jour — relancez clikae pour utiliser la nouvelle version."
T_UPDATE_FAILED="La commande de mise à jour a échoué — lancez-la vous-même, ou consultez la page de la release."
T_UPDATE_MANUAL="Mettez à jour clikae avec votre installateur, ou récupérez-le ici :"
T_DRY_SEEN="relevé %s"
# new-tank / rename prompts
T_NEWTANK_TITLE="Nouveau réservoir — choisissez un CLI"
T_NEWTANK_PROFILE="Nom du réservoir pour %s (ex. work, personal) : "
T_NEWTANK_CANCEL="Annulé — aucun réservoir créé."
T_NEWTANK_NONAME="Annulé — aucun nom saisi."
T_RENAME_FOR="Renommer"
T_RENAME_NEW="Nouveau nom : "
T_RENAME_CANCEL="Annulé — nom inchangé."
# filter / help / misc
T_FILTER_PROMPT="filtrer : "
T_FILTER_NONE="aucun résultat"
T_HELP_TITLE="clikae — touches"
T_HELP_AGY="agy (Antigravity) est le mode power : 'n' → agy, ou 'clikae init agy <nom>', prend la main sur ~/.gemini (demande d'abord)."
T_DOTS_TITLE="Points = carburant"
T_DOT_READY="prêt"
T_DOT_DRY="à sec (quota dépassé)"
T_DOT_WEEK="% hebdo (BETA)"
T_DOT_NONE="aucun relevé"
T_HELP_DISMISS="une touche pour fermer"
T_PICKER_HINT="haut/bas déplacer · Enter choisir · q annuler"
T_LANG_SET="Langue de l'interface : %s"
T_LANG_UNKNOWN="Langue inconnue : %s  (choix : %s)"

# French pluralises with -s; "pour" avoids participle agreement ("répartis") —
# override the English summary. 1 réservoir pour 1 moteur / N réservoirs…
i18n_summary() {
  local n="$1" m="$2"
  printf '%s réservoir%s pour %s moteur%s' \
    "$n" "$([ "$n" = 1 ] || echo s)" "$m" "$([ "$m" = 1 ] || echo s)"
}
