-- LD - Murloc Run
-- Le jeu du dinosaure de Chrome, version Murloc, dans la forêt d'Elwynn.
-- Commandes : /mrun (ou /murloc), /mrun top, /mrun annonce, /mrun icone

local ADDON, ns = ...
local L = ns.L
local PREFIX = "LDMRUN"

------------------------------------------------------------------------
-- Réglages
------------------------------------------------------------------------
local W, H               = 640, 220   -- zone de jeu
local GROUND             = 40         -- hauteur de la route
local GRAVITY            = -2300
local JUMP_V             = 780
local FASTFALL_V         = -1100
local START_SPEED        = 280
local MAX_SPEED          = 760
local ACCEL              = 8          -- px/s gagnés chaque seconde
local SCORE_DIV          = 12         -- distance (px) par point
local MURLOC_X           = 70
local MURLOC_W, MURLOC_H = 30, 38     -- hitbox du murloc
local HIT_MARGIN         = 4          -- tolérance de collision

-- Modèle 3D : si l'ID ne charge pas, l'addon bascule sur l'icône.
local MURLOC_DISPLAY_ID  = 15369
local MODEL_SIZE         = 96
local MODEL_OFFX         = -32
-- Client « forever » (WOW_PROJECT_ID 18, interface 16xxx) : plus grand, modèle plus bas ; autres clients : réglages d'origine
local IS_FOREVER         = WOW_PROJECT_ID == 18 or (select(4, GetBuildInfo()) or 0) >= 16000
local DEFAULT_SCALE      = IS_FOREVER and 1.6 or 1
local MODEL_OFFY         = IS_FOREVER and -34 or -18
local MURLOC_ICON        = "Interface\\AddOns\\LD_MurlocRun\\Media\\icon"

local ANIM = { stand = 0, death = 1, run = 5, jump = 38 }

------------------------------------------------------------------------
-- État
------------------------------------------------------------------------
local db, me, realm
local f, g, ov, scoreText, msgText, mdl, iconF, board, mmb
local state, overAt = "idle", 0          -- idle / run / pause / over
local speed, dist, nextSpawn = 0, 0, 0
local my, vy = 0, 0
local layers, obstacles, pool = {}, {}, {}
local curAnim, lastShown = nil, -1
local boardTab = "guild"

------------------------------------------------------------------------
-- Utilitaires
------------------------------------------------------------------------
local function Rect(parent, x, y, w, h, r, gg, b, a)
  local t = parent:CreateTexture(nil, "ARTWORK")
  parent._sub = math.min((parent._sub or -8) + 1, 7)
  t:SetDrawLayer("ARTWORK", parent._sub)
  t:SetColorTexture(r, gg, b, a or 1)
  t:SetSize(w, h)
  t:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x, y)
  return t
end

local function Gradient(t, top, bottom)
  t:SetTexture("Interface\\Buttons\\WHITE8X8")
  if CreateColor and pcall(t.SetGradient, t, "VERTICAL",
      CreateColor(bottom[1], bottom[2], bottom[3], 1), CreateColor(top[1], top[2], top[3], 1)) then
    return
  end
  if t.SetGradientAlpha then
    t:SetGradientAlpha("VERTICAL", bottom[1], bottom[2], bottom[3], 1, top[1], top[2], top[3], 1)
  end
end

local function Full(name)
  if not name or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  return name .. "-" .. (realm or "")
end

local function Short(name)
  return Ambiguate and Ambiguate(name, "short") or (name:match("^[^-]+") or name)
end

local function Score() return math.floor(dist / SCORE_DIV) end

------------------------------------------------------------------------
-- Communication (invisible, via messages d'addon)
------------------------------------------------------------------------
local function Send(msg, chan, target)
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(PREFIX, msg, chan, target)
  elseif SendAddonMessage then
    SendAddonMessage(PREFIX, msg, chan, target)
  end
end

-- Retail déplace SendChatMessage dans C_ChatInfo ; les clients Classic gardent la globale
local function Say(msg, chan)
  if C_ChatInfo and C_ChatInfo.SendChatMessage then
    C_ChatInfo.SendChatMessage(msg, chan)
  else
    SendChatMessage(msg, chan)
  end
end

local function Friends(onlineOnly)
  local list = {}
  if C_FriendList and C_FriendList.GetNumFriends then
    for i = 1, C_FriendList.GetNumFriends() do
      local info = C_FriendList.GetFriendInfoByIndex(i)
      if info and info.name and (info.connected or not onlineOnly) then list[#list + 1] = info.name end
    end
  elseif GetNumFriends then
    for i = 1, GetNumFriends() do
      local name, _, _, _, connected = GetFriendInfo(i)
      if name and (connected or not onlineOnly) then list[#list + 1] = name end
    end
  end
  return list
end

local function Broadcast(msg)
  if IsInGuild() then Send(msg, "GUILD") end
  if IsInRaid() then Send(msg, "RAID") elseif IsInGroup() then Send(msg, "PARTY") end
  for _, n in ipairs(Friends(true)) do Send(msg, "WHISPER", n) end
end

local function RequestScores()
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
  elseif GuildRoster then GuildRoster() end
  Broadcast("Q")
end

------------------------------------------------------------------------
-- Classement
------------------------------------------------------------------------
local RefreshBoard, Recenter
local BOARD_W = 230

local function GuildSet()
  local s = {}
  if IsInGuild() then
    for i = 1, GetNumGuildMembers() do
      local n = GetGuildRosterInfo(i)
      if n then s[Full(n)] = true end
    end
  end
  return s
end

local function FriendSet()
  local s = {}
  for _, n in ipairs(Friends(false)) do s[Full(n)] = true end
  return s
end

RefreshBoard = function()
  if not board or not board:IsShown() then return end
  local myGuild = IsInGuild() and GetGuildInfo("player")
  local gs = boardTab == "guild" and GuildSet()
  local fs = boardTab == "friends" and FriendSet()
  local list, players = {}, 0

  for name, best in pairs(db.chars) do
    if name == me or boardTab == "all" then
      list[#list + 1] = { name = name, best = best, mine = true }
    end
  end
  for name, d in pairs(db.others) do
    players = players + 1
    local ok = boardTab == "all"
      or (gs and (gs[name] or (myGuild and d.guild == myGuild)))
      or (fs and fs[name])
    if ok and d.best then list[#list + 1] = { name = name, best = d.best } end
  end
  table.sort(list, function(a, b) return a.best > b.best end)

  for i, row in ipairs(board.rows) do
    local e = list[i]
    if e then
      local color = e.mine and "|cff66ff66" or (i == 1 and "|cffffd100") or (i == 2 and "|cffd0d0d0")
        or (i == 3 and "|cffd08040") or "|cffffffff"
      row.name:SetText(("%s%d. %s|r"):format(color, i, Short(e.name)))
      row.score:SetText(color .. e.best .. "|r")
    else
      row.name:SetText(i == 1 and "|cff888888" .. L.no_scores .. "|r" or "")
      row.score:SetText("")
    end
  end
  for key, btn in pairs(board.tabs) do btn:SetEnabled(key ~= boardTab) end
  board.status:SetText(("|cff888888" .. L.players_known .. "|r"):format(players))
end

local function ShowBoard()
  board:Show()
  RequestScores()
  RefreshBoard()
end

------------------------------------------------------------------------
-- Murloc
------------------------------------------------------------------------
local function Anim(a)
  if mdl and mdl:IsShown() and mdl.SetAnimation and curAnim ~= a then
    curAnim = a
    mdl:SetAnimation(a)
  end
end

local function LoadModel()
  iconF:Hide()
  mdl:Show()
  mdl:SetDisplayInfo(MURLOC_DISPLAY_ID)
  mdl:SetFacing(math.pi / 2) -- regarde vers la droite
  curAnim = nil
  Anim(state == "run" and ANIM.run or ANIM.stand)
  C_Timer.After(0.6, function()
    if mdl.GetModelFileID then
      local fid = mdl:GetModelFileID()
      if not fid or fid == 0 then mdl:Hide(); iconF:Show() end
    end
  end)
end

local function PlaceMurloc()
  local y = GROUND + my
  mdl:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", MURLOC_X + MODEL_OFFX, y + MODEL_OFFY)
  iconF:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", MURLOC_X - 3, y)
end

------------------------------------------------------------------------
-- Décor (parallaxe)
------------------------------------------------------------------------
local function NewLayer(level, factor, spacing, count, build)
  local L = { factor = factor, items = {}, span = spacing * count }
  for i = 1, count do
    local it = CreateFrame("Frame", nil, g)
    it:SetFrameLevel(level)
    it.x = (i - 1) * spacing + math.random(0, math.floor(spacing * 0.3))
    build(it)
    it:SetSize(it.w, 60)
    it:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", it.x, it.y)
    L.items[i] = it
  end
  layers[#layers + 1] = L
end

local function BuildScenery(base)
  -- Ciel + soleil
  local sky = g:CreateTexture(nil, "BACKGROUND")
  sky:SetAllPoints()
  Gradient(sky, { 0.36, 0.60, 0.88 }, { 0.82, 0.91, 0.96 })
  local sun = g:CreateTexture(nil, "BORDER")
  sun:SetColorTexture(1, 0.94, 0.62, 1)
  sun:SetSize(22, 22)
  sun:SetPoint("TOPLEFT", g, "TOPLEFT", 40, -22)

  -- Nuages
  NewLayer(base + 1, 0.08, 160, 6, function(it)
    it.w, it.y = 70, math.random(H - 70, H - 40)
    Rect(it, 0, 0, 70, 10, 1, 1, 1, 0.85)
    Rect(it, 12, 8, 34, 10, 1, 1, 1, 0.85)
    Rect(it, 34, 4, 26, 16, 1, 1, 1, 0.85)
  end)

  -- Collines lointaines
  NewLayer(base + 2, 0.15, 150, 6, function(it)
    local h = math.random(50, 95)
    it.w, it.y = 180, GROUND - 2
    Rect(it, 0, 0, 180, h * 0.55, 0.24, 0.42, 0.33)
    Rect(it, 25, 0, 130, h * 0.8, 0.22, 0.39, 0.31)
    Rect(it, 60, 0, 60, h, 0.20, 0.36, 0.30)
  end)

  -- Arbres d'Elwynn
  NewLayer(base + 3, 0.4, 95, 9, function(it)
    local th, c = math.random(28, 48), math.random(0, 10)
    it.w, it.y = 90, GROUND - 2
    Rect(it, 40, 0, 10, th + 10, 0.36, 0.24, 0.14)
    Rect(it, 18, th - 6, 54, 26 + c, 0.12, 0.36, 0.14)
    Rect(it, 12, th + 8, 66, 24, 0.17, 0.46, 0.19)
    Rect(it, 24, th + 26 + c, 42, 18, 0.22, 0.55, 0.23)
    Rect(it, 30, th + 36 + c, 18, 8, 0.32, 0.66, 0.28)
  end)

  -- Sol : herbe + route
  local ground = CreateFrame("Frame", nil, g)
  ground:SetFrameLevel(base + 4)
  ground:SetSize(W, GROUND)
  ground:SetPoint("BOTTOMLEFT")
  Rect(ground, 0, 0, W, GROUND - 14, 0.27, 0.50, 0.19)
  Rect(ground, 0, GROUND - 14, W, 14, 0.58, 0.47, 0.30)
  Rect(ground, 0, GROUND - 2, W, 2, 0.68, 0.57, 0.38)
  Rect(ground, 0, GROUND - 16, W, 2, 0.20, 0.40, 0.15)

  -- Cailloux et touffes d'herbe (vitesse du sol)
  NewLayer(base + 5, 1.0, 45, 16, function(it)
    it.w = 6
    if math.random() < 0.5 then
      it.y = GROUND - 10
      Rect(it, 0, 0, 4, 3, 0.45, 0.37, 0.24)
    else
      it.y = math.random(6, 18)
      Rect(it, 0, 0, 2, 5, 0.18, 0.38, 0.13)
      Rect(it, 3, 0, 2, 7, 0.18, 0.38, 0.13)
    end
  end)
end

------------------------------------------------------------------------
-- Obstacles
------------------------------------------------------------------------
local TYPES = {
  stump = { w = 22, h = 28, build = function(o)
    Rect(o, -2, 0, 26, 5, 0.33, 0.21, 0.10)
    Rect(o, 0, 0, 22, 24, 0.40, 0.26, 0.13)
    Rect(o, 2, 22, 18, 6, 0.66, 0.50, 0.30)
    Rect(o, 6, 24, 10, 2, 0.52, 0.38, 0.22)
  end },
  rock = { w = 34, h = 20, build = function(o)
    Rect(o, 0, 0, 34, 12, 0.42, 0.42, 0.46)
    Rect(o, 4, 10, 26, 8, 0.50, 0.50, 0.54)
    Rect(o, 10, 16, 14, 4, 0.62, 0.62, 0.66)
  end },
  crate = { w = 24, h = 24, build = function(o)
    Rect(o, 0, 0, 24, 24, 0.55, 0.38, 0.18)
    Rect(o, 0, 0, 24, 3, 0.38, 0.25, 0.11)
    Rect(o, 0, 21, 24, 3, 0.38, 0.25, 0.11)
    Rect(o, 10, 0, 4, 24, 0.38, 0.25, 0.11)
  end },
  bat = { w = 30, h = 14, fly = true, build = function(o)
    Rect(o, 10, 2, 10, 10, 0.22, 0.16, 0.24)
    o.wl = Rect(o, 0, 6, 11, 4, 0.30, 0.22, 0.32)
    o.wr = Rect(o, 19, 6, 11, 4, 0.30, 0.22, 0.32)
    Rect(o, 11, 8, 2, 2, 1, 0.3, 0.2)
  end },
}

local obstacleLevel

local function Acquire(kind)
  local p = pool[kind]
  local o = p and table.remove(p)
  if not o then
    local T = TYPES[kind]
    o = CreateFrame("Frame", nil, g)
    o:SetFrameLevel(obstacleLevel)
    o:SetSize(T.w, T.h)
    o.kind, o.w, o.h = kind, T.w, T.h
    T.build(o)
  end
  o:Show()
  obstacles[#obstacles + 1] = o
  return o
end

local function Release(i)
  local o = table.remove(obstacles, i)
  o:Hide()
  pool[o.kind] = pool[o.kind] or {}
  table.insert(pool[o.kind], o)
end

local function Spawn()
  local r, kind = math.random(), nil
  if Score() > 150 and r < 0.28 then kind = "bat"
  elseif r < 0.6 then kind = "stump"
  elseif r < 0.85 then kind = "rock"
  else kind = "crate" end
  local o = Acquire(kind)
  o.x = W + 10
  o.y = GROUND
  if TYPES[kind].fly then
    -- bas : il faut sauter / haut : surtout ne pas sauter
    o.y = GROUND + (math.random() < 0.5 and 6 or 44)
  end
  o:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", o.x, o.y)
end

------------------------------------------------------------------------
-- Boucle de jeu
------------------------------------------------------------------------
local function UpdateScore(force)
  local s = Score()
  if force or s ~= lastShown then
    lastShown = s
    scoreText:SetText(("|cff999999HI %05d|r   %05d"):format(db.chars[me] or 0, s))
  end
end

local function Reset()
  for i = #obstacles, 1, -1 do Release(i) end
  speed, dist, my, vy, nextSpawn = START_SPEED, 0, 0, 0, 350
  state = "run"
  msgText:SetText("")
  Anim(ANIM.run)
  PlaceMurloc()
  UpdateScore(true)
end

local function GameOver()
  state, overAt = "over", GetTime()
  Anim(ANIM.death)
  local s = Score()
  local line
  if s > (db.chars[me] or 0) then
    db.chars[me] = s
    line = "|cff66ff66" .. L.new_record:format(s) .. "|r"
    Broadcast("S:" .. s)
    if db.announce and IsInGuild() then
      Say(L.msg_new_record:format(s), "GUILD")
    end
    RefreshBoard()
  else
    line = L.game_over
  end
  msgText:SetText(line .. "\n|cffaaaaaa" .. L.space_replay .. "|r")
  UpdateScore(true)
end

local function Jump()
  if state == "idle" then Reset() return end
  if state == "pause" then
    state = "run"; msgText:SetText("")
    Anim(my > 0 and ANIM.jump or ANIM.run)
    return
  end
  if state == "over" then
    if GetTime() - overAt > 0.5 then Reset() end
    return
  end
  if my <= 0 then
    vy, my = JUMP_V, 0.1
    Anim(ANIM.jump)
  end
end

local function FastFall()
  if state == "run" and my > 0 then vy = math.min(vy, FASTFALL_V) end
end

local function OnUpdate(_, elapsed)
  if state ~= "run" then return end
  local dt = math.min(elapsed, 0.05)

  speed = math.min(MAX_SPEED, speed + ACCEL * dt)
  dist = dist + speed * dt

  if my > 0 or vy > 0 then
    vy = vy + GRAVITY * dt
    my = my + vy * dt
    if my <= 0 then my, vy = 0, 0; Anim(ANIM.run) end
    PlaceMurloc()
  end

  for _, L in ipairs(layers) do
    local d = speed * L.factor * dt
    for _, it in ipairs(L.items) do
      it.x = it.x - d
      if it.x < -it.w then it.x = it.x + L.span end
      it:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", it.x, it.y)
    end
  end

  nextSpawn = nextSpawn - speed * dt
  if nextSpawn <= 0 then
    Spawn()
    nextSpawn = math.random(260, 520) + speed * 0.35
  end

  local mx1, mx2 = MURLOC_X + HIT_MARGIN, MURLOC_X + MURLOC_W - HIT_MARGIN
  local my1, my2 = GROUND + my + HIT_MARGIN, GROUND + my + MURLOC_H - HIT_MARGIN
  for i = #obstacles, 1, -1 do
    local o = obstacles[i]
    o.x = o.x - speed * dt
    if o.x < -o.w - 10 then
      Release(i)
    else
      o:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", o.x, o.y)
      if o.wl then
        o.ft = (o.ft or 0) + dt
        if o.ft > 0.12 then
          o.ft, o.up = 0, not o.up
          local wy = o.up and 10 or 3
          o.wl:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", 0, wy)
          o.wr:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", 19, wy)
        end
      end
      if o.x < mx2 and o.x + o.w > mx1 and o.y < my2 and o.y + o.h > my1 then
        GameOver()
        return
      end
    end
  end

  UpdateScore()
end

------------------------------------------------------------------------
-- Interface
------------------------------------------------------------------------
local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8X8",
  edgeFile = "Interface\\Buttons\\WHITE8X8",
  edgeSize = 1,
}
local TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local function Panel(name, parent, w, h)
  local p = CreateFrame("Frame", name, parent, TEMPLATE)
  p:SetSize(w, h)
  if p.SetBackdrop then
    p:SetBackdrop(BACKDROP)
    p:SetBackdropColor(0.05, 0.06, 0.08, 0.92)
    p:SetBackdropBorderColor(1, 1, 1, 0.12)
  end
  return p
end

-- Centre le jeu à l'écran ; classement ouvert, c'est l'ensemble jeu + classement qui est centré
Recenter = function()
  local offset = (board and board:IsShown()) and -(BOARD_W + 4) / 2 or 0
  f:ClearAllPoints()
  f:SetPoint("CENTER", UIParent, "CENTER", offset, 120)
end

local function BuildBoard()
  board = Panel(nil, f, BOARD_W, H + 40)
  board:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, 0)
  board:SetScript("OnShow", Recenter)
  board:SetScript("OnHide", Recenter)
  board:Hide()

  local t = board:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("TOPLEFT", 10, -9)
  t:SetText(L.leaderboard)

  board.tabs = {}
  local tabs = { { "guild", L.tab_guild }, { "friends", L.tab_friends }, { "all", L.tab_all } }
  for i, def in ipairs(tabs) do
    local b = CreateFrame("Button", nil, board, "UIPanelButtonTemplate")
    b:SetSize(68, 20)
    b:SetPoint("TOPLEFT", 8 + (i - 1) * 72, -28)
    b:SetText(def[2])
    b:SetScript("OnClick", function() boardTab = def[1]; RefreshBoard() end)
    board.tabs[def[1]] = b
  end

  board.rows = {}
  for i = 1, 10 do
    local y = -54 - (i - 1) * 16
    local n = board:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    n:SetPoint("TOPLEFT", 12, y)
    n:SetJustifyH("LEFT")
    local s = board:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s:SetPoint("TOPRIGHT", -12, y)
    board.rows[i] = { name = n, score = s }
  end

  board.status = board:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  board.status:SetPoint("BOTTOM", 0, 34)

  local r = CreateFrame("Button", nil, board, "UIPanelButtonTemplate")
  r:SetSize(106, 20)
  r:SetPoint("BOTTOMLEFT", 8, 8)
  r:SetText(L.refresh)
  r:SetScript("OnClick", function() RequestScores(); C_Timer.After(1.5, RefreshBoard) end)

  -- Partager le record selon l'onglet : Guilde -> /g, Amis -> groupe, Tous -> /dire
  local SHARE = {
    guild   = { function() return IsInGuild() and "GUILD" end, L.no_guild },
    friends = { function() return (IsInRaid() and "RAID") or (IsInGroup() and "PARTY") end, L.no_group },
    all     = { function() return "SAY" end },
  }
  local s = CreateFrame("Button", nil, board, "UIPanelButtonTemplate")
  s:SetSize(106, 20)
  s:SetPoint("BOTTOMRIGHT", -8, 8)
  s:SetText(L.share)
  s:SetScript("OnClick", function()
    local best = db.chars[me] or 0
    if best <= 0 then
      print("|cff33ff99Murloc Run|r : " .. L.no_record_yet)
      return
    end
    local def = SHARE[boardTab]
    local chan = def[1]()
    if not chan then
      print("|cff33ff99Murloc Run|r : " .. def[2])
      return
    end
    Say(L.msg_my_record:format(best), chan)
  end)
end

local function BuildUI()
  f = Panel("LDMurlocRunFrame", UIParent, W + 16, H + 40)
  f:SetFrameStrata("DIALOG")
  f:SetScale(db.scale or DEFAULT_SCALE)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Recenter()
  f:Hide()

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -9)
  title:SetText(L.title)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  local top = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  top:SetSize(90, 20)
  top:SetPoint("TOPRIGHT", -30, -6)
  top:SetText(L.leaderboard)
  top:SetScript("OnClick", function() if board:IsShown() then board:Hide() else ShowBoard() end end)

  g = CreateFrame("Frame", nil, f)
  g:SetSize(W, H)
  g:SetPoint("BOTTOMLEFT", 8, 8)
  if g.SetClipsChildren then g:SetClipsChildren(true) end
  local base = g:GetFrameLevel()
  obstacleLevel = base + 6

  BuildScenery(base)

  mdl = CreateFrame("PlayerModel", nil, g)
  mdl:SetFrameLevel(base + 7)
  mdl:SetSize(MODEL_SIZE, MODEL_SIZE)
  mdl:SetScript("OnShow", function(self)
    self:SetDisplayInfo(MURLOC_DISPLAY_ID)
    self:SetFacing(math.pi / 2)
    curAnim = nil
    Anim(state == "run" and ANIM.run or (state == "over" and ANIM.death) or ANIM.stand)
  end)

  iconF = CreateFrame("Frame", nil, g)
  iconF:SetFrameLevel(base + 7)
  iconF:SetSize(36, 36)
  local ic = iconF:CreateTexture(nil, "ARTWORK")
  ic:SetAllPoints()
  ic:SetTexture(MURLOC_ICON)
  ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  iconF:Hide()

  ov = CreateFrame("Frame", nil, g)
  ov:SetFrameLevel(base + 8)
  ov:SetAllPoints()
  scoreText = ov:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  scoreText:SetPoint("TOPRIGHT", -10, -8)
  scoreText:SetShadowOffset(1, -1)
  msgText = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  msgText:SetPoint("CENTER", 0, 30)
  msgText:SetShadowOffset(1, -1)
  msgText:SetText(L.intro_1 .. "\n|cffaaaaaa" .. L.intro_2 .. "|r")

  -- Contrôles
  g:EnableMouse(true)
  g:SetScript("OnMouseDown", Jump)
  g:EnableKeyboard(true)
  g:SetScript("OnKeyDown", function(self, key)
    local mine = key == "SPACE" or key == "UP" or key == "W" or key == "DOWN" or key == "S" or key == "ESCAPE"
    if not InCombatLockdown() then self:SetPropagateKeyboardInput(not mine) end
    if not mine then return end
    if key == "ESCAPE" then f:Hide()
    elseif key == "DOWN" or key == "S" then FastFall()
    else Jump() end
  end)
  g:SetScript("OnUpdate", OnUpdate)

  f:SetScript("OnShow", function()
    Recenter()
    if not f.modelLoaded then f.modelLoaded = true; LoadModel() end
    if state == "pause" then
      msgText:SetText(L.pause .. "\n|cffaaaaaa" .. L.space_resume .. "|r")
    end
    PlaceMurloc()
    UpdateScore(true)
  end)
  f:SetScript("OnHide", function()
    if state == "run" then state = "pause" end
  end)

  BuildBoard()
end

------------------------------------------------------------------------
-- Icône de la minimap (clic : jeu, clic droit : classement, glisser : déplacer)
------------------------------------------------------------------------
local function PlaceMinimapButton()
  local a = math.rad(db.minimapAngle or 215)
  local r = (Minimap:GetWidth() / 2) + 5
  mmb:ClearAllPoints()
  mmb:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function BuildMinimapButton()
  -- Nom en LibDBIcon10_* : LD_UIModern range ces boutons dans sa colonne
  mmb = CreateFrame("Button", "LibDBIcon10_LDMurlocRun", Minimap)
  mmb:SetSize(31, 31)
  mmb:SetFrameStrata("MEDIUM")
  mmb:SetFrameLevel(8)
  mmb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mmb:RegisterForDrag("LeftButton")
  mmb:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = mmb:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER", 0, 1)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

  local ic = mmb:CreateTexture(nil, "ARTWORK")
  ic:SetSize(20, 20)
  ic:SetPoint("CENTER", 0, 1)
  ic:SetTexture(MURLOC_ICON)

  local border = mmb:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  mmb.icon, mmb.background, mmb.border = ic, bg, border   -- convention LibDBIcon

  mmb:SetScript("OnClick", function(_, btn)
    if btn == "RightButton" then
      f:Show(); ShowBoard()
    else
      f:SetShown(not f:IsShown())
    end
  end)

  mmb:SetScript("OnDragStart", function(self)
    if _G.LDUIM_MinimapFrame then return end   -- rangé dans la colonne de LD_UIModern
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local s = Minimap:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      db.minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
      PlaceMinimapButton()
    end)
  end)
  mmb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  mmb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(L.title)
    GameTooltip:AddLine(L.tip_click, 1, 1, 1)
    GameTooltip:AddLine(L.tip_rclick, 1, 1, 1)
    GameTooltip:AddLine(L.tip_drag, 0.6, 0.6, 0.6)    GameTooltip:Show()
  end)
  mmb:SetScript("OnLeave", GameTooltip_Hide)

  PlaceMinimapButton()
  mmb:SetShown(not db.hideMinimap)
end

------------------------------------------------------------------------
-- Événements
------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")

ev:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" and ... == ADDON then
    LDMurlocRunDB = LDMurlocRunDB or {}
    db = LDMurlocRunDB
    db.chars = db.chars or {}
    db.others = db.others or {}
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
      C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif RegisterAddonMessagePrefix then
      RegisterAddonMessagePrefix(PREFIX)
    end

  elseif event == "PLAYER_LOGIN" then
    realm = GetNormalizedRealmName() or (GetRealmName() or ""):gsub("%s", "")
    me = UnitName("player") .. "-" .. realm
    BuildUI()
    BuildMinimapButton()
    C_Timer.After(10, RequestScores)

  elseif event == "CHAT_MSG_ADDON" then
    local prefix, msg, channel, sender = ...
    if prefix ~= PREFIX or not me then return end
    sender = Full(sender)
    if not sender or sender == me then return end
    if msg == "Q" then
      local b = db.chars[me] or 0
      if b > 0 then
        if channel == "GUILD" or channel == "PARTY" or channel == "RAID" then
          Send("S:" .. b, channel)
        else
          Send("S:" .. b, "WHISPER", sender)
        end
      end
    else
      local s = tonumber(msg:match("^S:(%d+)$") or "")
      if s and s < 1000000 then
        local d = db.others[sender] or {}
        d.best, d.t = s, time()
        if channel == "GUILD" then d.guild = GetGuildInfo("player") end
        db.others[sender] = d
        RefreshBoard()
      end
    end

  elseif event == "GUILD_ROSTER_UPDATE" then
    RefreshBoard()

  elseif event == "PLAYER_REGEN_DISABLED" then
    if f and f:IsShown() then
      f:Hide()
      print("|cff33ff99Murloc Run|r : " .. L.combat_pause)
    end
  end
end)

------------------------------------------------------------------------
-- Commandes
------------------------------------------------------------------------
SLASH_LDMURLOCRUN1 = "/mrun"
SLASH_LDMURLOCRUN2 = "/murloc"
SlashCmdList.LDMURLOCRUN = function(arg)
  local cmd, rest = (arg or ""):match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "icone" then
    db.hideMinimap = not db.hideMinimap
    mmb:SetShown(not db.hideMinimap)
    print("|cff33ff99Murloc Run|r : " .. (db.hideMinimap and L.icon_hidden or L.icon_shown))
  elseif cmd == "taille" then
    local s = tonumber(rest)
    if s and s >= 0.8 and s <= 3 then
      db.scale = s
      f:SetScale(s)
      Recenter()
      print("|cff33ff99Murloc Run|r : taille x" .. s)
    else
      print("|cff33ff99Murloc Run|r : /mrun taille 0.8 - 3 (actuel : " .. (db.scale or DEFAULT_SCALE) .. ")")
    end
  elseif cmd == "top" then
    f:Show(); ShowBoard()
  elseif cmd == "annonce" then
    db.announce = not db.announce
    print("|cff33ff99Murloc Run|r : " .. (db.announce and L.announce_on or L.announce_off))
  else
    f:SetShown(not f:IsShown())
  end
end
