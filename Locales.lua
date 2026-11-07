-- LD - Murloc Run : textes traduits (français si le client est en frFR, anglais sinon)
local _, ns = ...

local en = {
  title          = "LD - Murloc Run",
  leaderboard    = "Leaderboard",
  tab_guild      = "Guild",
  tab_friends    = "Friends",
  tab_all        = "All",
  refresh        = "Refresh",
  share          = "Share",
  no_scores      = "No scores yet",
  players_known  = "%d player(s) with the addon known",
  intro_1        = "Space or click to run!",
  intro_2        = "Up / Space: jump   Down: fall fast",
  pause          = "Pause",
  space_resume   = "Space to resume",
  space_replay   = "Space to play again",
  new_record     = "New record: %d!",
  game_over      = "Mrglglglgl… Game over",
  msg_new_record = "[Murloc Run] Mrglglgl! New record: %d",
  msg_my_record  = "[Murloc Run] Mrglglgl! My record: %d",
  no_record_yet  = "no record to share yet.",
  no_guild       = "you are not in a guild.",
  no_group       = "you are not in a group.",
  combat_pause   = "combat! Game paused. Mrgl!",
  icon_hidden    = "minimap icon hidden.",
  icon_shown     = "minimap icon shown.",
  announce_on    = "record announcements in guild chat enabled.",
  announce_off   = "record announcements in guild chat disabled.",
  tip_click      = "Click: play",
  tip_rclick     = "Right-click: leaderboard",
  tip_drag       = "Drag: move the icon",
}

local fr = {
  leaderboard    = "Classement",
  tab_guild      = "Guilde",
  tab_friends    = "Amis",
  tab_all        = "Tous",
  refresh        = "Actualiser",
  share          = "Partager",
  no_scores      = "Aucun score pour l'instant",
  players_known  = "%d joueur(s) avec l'addon connu(s)",
  intro_1        = "Espace ou clic pour courir !",
  intro_2        = "Haut / Espace : sauter   Bas : retomber vite",
  pause          = "Pause",
  space_resume   = "Espace pour reprendre",
  space_replay   = "Espace pour rejouer",
  new_record     = "Nouveau record : %d !",
  game_over      = "Mrglglglgl… Partie terminée",
  msg_new_record = "[Murloc Run] Mrglglgl ! Nouveau record : %d",
  msg_my_record  = "[Murloc Run] Mrglglgl ! Mon record : %d",
  no_record_yet  = "pas encore de record à partager.",
  no_guild       = "pas de guilde.",
  no_group       = "pas de groupe.",
  combat_pause   = "combat ! Partie mise en pause. Mrgl !",
  icon_hidden    = "icône de la minimap masquée.",
  icon_shown     = "icône de la minimap affichée.",
  announce_on    = "annonce des records en guilde activée.",
  announce_off   = "annonce des records en guilde désactivée.",
  tip_click      = "Clic : jouer",
  tip_rclick     = "Clic droit : classement",
  tip_drag       = "Glisser : déplacer l'icône",
}

local L = setmetatable({}, { __index = function(_, k) return k end })
for k, v in pairs(en) do L[k] = v end
if GetLocale() == "frFR" then
  for k, v in pairs(fr) do L[k] = v end
end
ns.L = L
