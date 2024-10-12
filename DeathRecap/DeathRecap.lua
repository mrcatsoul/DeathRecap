local ADDON_NAME, core = ...

local _G = _G
local tonumber = tonumber
local band = bit.band
local math_ceil, math_floor = math.ceil, math.floor
local format, strupper, strsub = string.format, string.upper, string.sub
local tsort, twipe = table.sort, table.wipe

local CannotBeResurrected = CannotBeResurrected
local CopyTable = CopyTable
local CreateFrame = CreateFrame
local GetReleaseTimeRemaining = GetReleaseTimeRemaining
local GetSpellInfo = GetSpellInfo
local GetSpellLink = GetSpellLink
local HasSoulstone = HasSoulstone
local IsActiveBattlefieldArena = IsActiveBattlefieldArena
local IsFalling = IsFalling
local IsOutOfBounds = IsOutOfBounds
local RepopMe = RepopMe
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UseSoulstone = UseSoulstone
local UnitClass = UnitClass
local GetPlayerInfoByGUID = GetPlayerInfoByGUID
local UnitInParty = UnitInParty
local UnitInRaid = UnitInRaid
local UnitGUID = UnitGUID
local UnitName = UnitName

local ACTION_SWING = ACTION_SWING
local ARENA_SPECTATOR = ARENA_SPECTATOR
local COMBATLOG_FILTER_ME = COMBATLOG_FILTER_ME
local COMBATLOG_UNKNOWN_UNIT = COMBATLOG_UNKNOWN_UNIT
local DEATH_RELEASE_NOTIMER = DEATH_RELEASE_NOTIMER
local DEATH_RELEASE_SPECTATOR = DEATH_RELEASE_SPECTATOR
local DEATH_RELEASE_TIMER = DEATH_RELEASE_TIMER
local MINUTES = MINUTES
local SECONDS = SECONDS
local TEXT_MODE_A_STRING_VALUE_SCHOOL = TEXT_MODE_A_STRING_VALUE_SCHOOL

local lastDeathEvents
local index = 0
local deathList = {}
local eventList = {}
local settings = {}

-- local functions
local AddEvent
local HasEvents
local EraseEvents
local AddDeath
local GetDeathEvents
local GetTableInfo
local OpenRecap
local Spell_OnEnter
local Amount_OnEnter
local CreateDeathRecapFrame
local DeathRecapFrame

local select, next, type = select, next, type
local tinsert, tremove = table.insert, table.remove
local setmetatable = setmetatable

local playerClass = select(2, UnitClass("player"))
local LANG = GetLocale()
local NUM_DEATH_RECAP_EVENTS = 20

-------------------------------------------------------------------------------
-- C_Timer mimic
--
do
	local TickerPrototype = {}
	local TickerMetatable = {__index = TickerPrototype}

	local WaitTable = {}

	local new, del
	do
		local list = {cache = {}, trash = {}}
		setmetatable(list.trash, {__mode = "v"})

		function new()
			return tremove(list.cache) or {}
		end

		function del(t)
			if t then
				setmetatable(t, nil)
				for k, v in pairs(t) do
					t[k] = nil
				end
				tinsert(list.cache, 1, t)
				while #list.cache > 20 do
					tinsert(list.trash, 1, tremove(list.cache))
				end
			end
		end
	end

	local function WaitFunc(self, elapsed)
		local total = #WaitTable
		local i = 1

		while i <= total do
			local ticker = WaitTable[i]

			if ticker._cancelled then
				del(tremove(WaitTable, i))
				total = total - 1
			elseif ticker._delay > elapsed then
				ticker._delay = ticker._delay - elapsed
				i = i + 1
			else
				ticker._callback(ticker)

				if ticker._iterations == -1 then
					ticker._delay = ticker._duration
					i = i + 1
				elseif ticker._iterations > 1 then
					ticker._iterations = ticker._iterations - 1
					ticker._delay = ticker._duration
					i = i + 1
				elseif ticker._iterations == 1 then
					del(tremove(WaitTable, i))
					total = total - 1
				end
			end
		end

		if #WaitTable == 0 then
			self:Hide()
		end
	end

	local WaitFrame = _G.KPack_WaitFrame or CreateFrame("Frame", "KPack_WaitFrame", UIParent)
	WaitFrame:SetScript("OnUpdate", WaitFunc)

	local function AddDelayedCall(ticker, oldTicker)
		ticker = (oldTicker and type(oldTicker) == "table") and oldTicker or ticker
		tinsert(WaitTable, ticker)
		WaitFrame:Show()
	end

	local function ValidateArguments(duration, callback, callFunc)
		if type(duration) ~= "number" then
			error(format(
				"Bad argument #1 to '" .. callFunc .. "' (number expected, got %s)",
				duration ~= nil and type(duration) or "no value"
			), 2)
		elseif type(callback) ~= "function" then
			error(format(
				"Bad argument #2 to '" .. callFunc .. "' (function expected, got %s)",
				callback ~= nil and type(callback) or "no value"
			), 2)
		end
	end

	local function After(duration, callback, ...)
		ValidateArguments(duration, callback, "After")

		local ticker = new()

		ticker._iterations = 1
		ticker._delay = max(0.01, duration)
		ticker._callback = callback

		AddDelayedCall(ticker)
	end

	local function CreateTicker(duration, callback, iterations, ...)
		local ticker = new()
		setmetatable(ticker, TickerMetatable)

		ticker._iterations = iterations or -1
		ticker._delay = max(0.01, duration)
		ticker._duration = ticker._delay
		ticker._callback = callback

		AddDelayedCall(ticker)
		return ticker
	end

	local function NewTicker(duration, callback, iterations, ...)
		ValidateArguments(duration, callback, "NewTicker")
		return CreateTicker(duration, callback, iterations, ...)
	end

	local function NewTimer(duration, callback, ...)
		ValidateArguments(duration, callback, "NewTimer")
		return CreateTicker(duration, callback, 1, ...)
	end

	local function CancelTimer(ticker, silent)
		if ticker and ticker.Cancel then
			ticker:Cancel()
		elseif not silent then
			error("KPack.CancelTimer(timer[, silent]): '"..tostring(ticker).."' - no such timer registered")
		end
		return nil
	end

	function TickerPrototype:Cancel()
		self._cancelled = true
	end
	function TickerPrototype:IsCancelled()
		return self._cancelled
	end

	core.After = After
	core.NewTicker = NewTicker
	core.NewTimer = NewTimer
	core.CancelTimer = CancelTimer
end

-- color names 11.10.24 (mrcatsoul)
local classColors = {
  ["DEATHKNIGHT"] = "C41F3B",
  ["DRUID"] = "FF7D0A",
  ["HUNTER"] = "A9D271",
  ["MAGE"] = "40C7EB",
  ["PALADIN"] = "F58CBA",
  ["PRIEST"] = "FFFFFF",
  ["ROGUE"] = "FFF569",
  ["SHAMAN"] = "0070DE",
  ["WARLOCK"] = "8787ED",
  ["WARRIOR"] = "C79C6E",
}

local function colorName(name,unitid,guid,unknownColor,hyperLink,chathyperLink)
  local _name = (name and name:gsub("-.*$", "")) or (unitid and UnitName(unitid)) or (guid and select(6,GetPlayerInfoByGUID(guid))) or "UNKNOWN"
  
  local _class = (unitid and select(2,UnitClass(unitid))) or (guid and select(2,GetPlayerInfoByGUID(guid))) or (_name and _name~="" and _name~="UNKNOWN" and UnitIsPlayer(_name) and (UnitInParty(_name) or UnitInRaid(_name)) and select(2,UnitClass(_name)))

  local _guid = guid or (unitid and UnitGUID(unitid)) or (_name and _name~="" and _name~="UNKNOWN" and UnitIsPlayer(_name) and (UnitInParty(_name) or UnitInRaid(_name)) and UnitGUID(_name))
  
  local _realm = (name and name:match("-(.+)")) or (guid and select(7,GetPlayerInfoByGUID(guid))) or (unitid and select(2,UnitName(unitid))) or (_name and _name~="" and _name~="UNKNOWN" and UnitIsPlayer(_name) and (UnitInParty(_name) or UnitInRaid(_name)) and select(2,UnitName(_name)))
  
  -- повторная попытка получить инфу
  if not _guid and _name and _name~="" and _name~="UNKNOWN" and UnitIsPlayer(_name) and (UnitInParty(_name) or UnitInRaid(_name)) then
    _guid=UnitGUID(_name)
  end
  
  if not _class and _name and _name~="" and _name~="UNKNOWN" and UnitIsPlayer(_name) and (UnitInParty(_name) or UnitInRaid(_name)) then
    _class=select(2,UnitClass(_name))
  end
  
  if not _realm and _name and _name~="" and _name~="UNKNOWN" and UnitIsPlayer(_name) and (UnitInParty(_name) or UnitInRaid(_name)) then
    _,_realm=select(2,UnitName(_name))
  end
  
  local nameRealm
  if _realm and _realm~="" then
    nameRealm=_name.."-".._realm
  else
    nameRealm=_name
  end

  if hyperLink==nil then 
    hyperLink=1 
  end
  
  local classColor = _class and classColors[_class] or unknownColor or "989898"
  
  if hyperLink then
    if chathyperLink and not (nameRealm:find("UNKNOWN")) and guid and (tonumber(guid:sub(5, 5), 16) % 8 == 0) then
      _name = "|Hplayer:"..nameRealm.."|h"..nameRealm.."|h"
    elseif guid then
      _name = "|Hunit:" .. guid .. ":" .. nameRealm .. "|h" .. nameRealm .. "|h"
    end
  end
  
  return "|ccc"..classColor.._name.."|r"
end

function core:RegisterForEvent(event, callback, ...)
	if not self.frame then
		self.frame = CreateFrame("Frame")
		self.frame:SetScript("OnEvent", function(f, event, ...)
			for func, args in next, f.events[event] do
				func(unpack(args), ...)
			end
		end)
	end
	self.frame.events = self.frame.events or {}
	self.frame.events[event] = self.frame.events[event] or {}
	self.frame.events[event][callback] = {...}
	self.frame:RegisterEvent(event)
end

function AddEvent(timestamp, event, srcName, spellId, spellName, environmentalType, amount, overkill, school, resisted, blocked, absorbed, srcGuid, critical)
  if index > 0 and eventList[index].timestamp + 10 <= timestamp then
    index = 0
    twipe(eventList)
  end

  if index < settings["NUM_DEATH_RECAP_EVENTS"] then
    index = index + 1
  else
    index = 1
  end

  if not eventList[index] then
    eventList[index] = {}
  else
    twipe(eventList[index])
  end

  eventList[index].timestamp = timestamp
  eventList[index].event = event
  eventList[index].srcName = srcName
  eventList[index].spellId = spellId
  eventList[index].spellName = spellName
  eventList[index].environmentalType = environmentalType
  eventList[index].amount = amount
  eventList[index].overkill = overkill
  eventList[index].school = school
  eventList[index].resisted = resisted
  eventList[index].blocked = blocked
  eventList[index].absorbed = absorbed
  eventList[index].currentHP = UnitHealth("player")
  eventList[index].maxHP = UnitHealthMax("player")
  eventList[index].srcGuid = srcGuid
  eventList[index].critical = critical
end

function HasEvents()
  if lastDeathEvents then
    return #deathList > 0, #deathList
  else
    return false, #deathList
  end
end

function EraseEvents()
  if index > 0 then
    index = 0
    twipe(eventList)
  end
end

function AddDeath()
  if #eventList > 0 then
    local _, deathEvents = HasEvents()
    local deathIndex = deathEvents + 1
    deathList[deathIndex] = CopyTable(eventList)
    EraseEvents()
    return true
  end
  return false
end

function GetDeathEvents(recapID)
  if recapID and deathList[recapID] then
    local deathEvents = deathList[recapID]
    tsort(deathEvents, function(a, b) return a.timestamp > b.timestamp end)
    return deathEvents
  end
end

function GetTableInfo(data)
  local texture
  local nameIsNotSpell = false

  local event = data.event
  local spellId = data.spellId
  local spellName = data.spellName

  if event == "SWING_DAMAGE" then
    spellId = 6603
    --spellName = ACTION_SWING
    spellName = GetSpellInfo(spellId)
    texture = [=[Interface\icons\INV_Sword_04]=]
    nameIsNotSpell = true
  elseif event == "RANGE_DAMAGE" then
    --spellId = 75
    --spellName = ACTION_RANGED
    if spellId == 75 then
      texture = [=[Interface\icons\inv_weapon_bow_05]=] 
    elseif spellId == 5019 then
      texture = [=[Interface\icons\ability_shootwand]=] 
    end
    --nameIsNotSpell = true
  elseif event == "ENVIRONMENTAL_DAMAGE" then
    local environmentalType = data.environmentalType
    environmentalType = strupper(environmentalType)
    spellName = _G["ACTION_ENVIRONMENTAL_DAMAGE_" .. environmentalType]
    nameIsNotSpell = true

    if environmentalType == "DROWNING" then
      texture = "spell_shadow_demonbreath"
    elseif environmentalType == "FALLING" then
      texture = "ability_rogue_quickrecovery"
    elseif environmentalType == "FIRE" or environmentalType == "LAVA" then
      texture = "spell_fire_fire"
    elseif environmentalType == "SLIME" then
      texture = "inv_misc_slime_01"
    elseif environmentalType == "FATIGUE" then
      texture = "ability_creature_cursed_05"
    else
      texture = "ability_creature_cursed_05"
    end

    texture = "Interface\\Icons\\" .. texture
  end

  if spellName and nameIsNotSpell then
    spellName = format("|Haction:%s|h%s|h", event, spellName)
  end

  if spellId and not texture then
    texture = select(3, GetSpellInfo(spellId)) or [=[Interface\icons\INV_Misc_QuestionMark]=]
  end
  
  --print(spellId, spellName, texture)
  return spellId, spellName, texture
end

function OpenRecap(recapID)
  local self = DeathRecapFrame

  if self:IsShown() and self.recapID == recapID then
    self:Hide()
    return
  end

  local deathEvents = GetDeathEvents(recapID)
  if not deathEvents then
    return
  end

  self.recapID = recapID

  if not deathEvents or #deathEvents <= 0 then
    for i = 1, settings["NUM_DEATH_RECAP_EVENTS"] do
      self.DeathRecapEntry[i]:Hide()
    end

    self.Unavailable:Show()
    return
  end

  self.Unavailable:Hide()

  local highestDmgIdx, highestDmgAmount = 1, 0
  self.DeathTimeStamp = nil

  for i = 1, #deathEvents do
    local entry = self.DeathRecapEntry[i]
    local dmgInfo = entry.DamageInfo
    local evtData = deathEvents[i]
    local spellId, spellName, texture = GetTableInfo(evtData)
    
    if i == 1 then
      entry:SetPoint("BOTTOM", DeathRecapContentFrame, "BOTTOM", 15, -(#deathEvents*20))
    else
      entry:SetPoint("TOP", DeathRecapFrame.DeathRecapEntry[i - 1], "TOP", 0, 40)
    end

    entry:Show()
    self.DeathTimeStamp = self.DeathTimeStamp or evtData.timestamp

    if evtData.amount then
      local amountStr = -evtData.amount
      dmgInfo.Amount:SetText(amountStr)
      dmgInfo.AmountLarge:SetText(amountStr)
      dmgInfo.amount = evtData.amount
      
      dmgInfo.dmgExtraStr = ""
      if evtData.overkill and evtData.overkill > 0 then
        dmgInfo.dmgExtraStr = format("(%d "..(LANG == "ruRU" and "избыточного" or "Overkill")..")", evtData.overkill)
        dmgInfo.amount = evtData.amount - evtData.overkill
      end
      if evtData.absorbed and evtData.absorbed > 0 then
        dmgInfo.dmgExtraStr = dmgInfo.dmgExtraStr .. " " .. format("(%d "..(LANG == "ruRU" and "поглощено" or "Absorbed")..")", evtData.absorbed)
        dmgInfo.amount = evtData.amount - evtData.absorbed
      end
      if evtData.resisted and evtData.resisted > 0 then
        dmgInfo.dmgExtraStr = dmgInfo.dmgExtraStr .. " " .. format("(%d "..(LANG == "ruRU" and "сопротивление" or "Resisted")..")", evtData.resisted)
        dmgInfo.amount = evtData.amount - evtData.resisted
      end
      if evtData.blocked and evtData.blocked > 0 then
        dmgInfo.dmgExtraStr = dmgInfo.dmgExtraStr .. " " .. format("(%d "..(LANG == "ruRU" and "заблокировано" or "Blocked")..")", evtData.blocked)
        dmgInfo.amount = evtData.amount - evtData.blocked
      end

      if evtData.amount > highestDmgAmount then
        highestDmgIdx = i
        highestDmgAmount = evtData.amount
      end

      if evtData.critical then
        dmgInfo.critical = evtData.critical
        dmgInfo.Amount:Hide()
        dmgInfo.AmountLarge:Show()
      else
        dmgInfo.Amount:Show()
        dmgInfo.AmountLarge:Hide()
      end
    else
      dmgInfo.Amount:SetText("")
      dmgInfo.AmountLarge:SetText("")
      dmgInfo.amount = nil
      dmgInfo.dmgExtraStr = nil
    end

    dmgInfo.timestamp = evtData.timestamp
    dmgInfo.hpPercent = math_floor(evtData.currentHP / evtData.maxHP * 100)

    dmgInfo.spellName = spellName

    dmgInfo.caster = evtData.srcName or COMBATLOG_UNKNOWN_UNIT
    dmgInfo.casterGuid = evtData.srcGuid

    if evtData.school and evtData.school > 1 then
      local colorArray = CombatLog_Color_ColorArrayBySchool(evtData.school)
      entry.SpellInfo.FrameIcon:SetBackdropBorderColor(colorArray.r, colorArray.g, colorArray.b)
    else
      entry.SpellInfo.FrameIcon:SetBackdropBorderColor(0, 0, 0)
    end

    dmgInfo.school = evtData.school

    entry.SpellInfo.Caster:SetText((LANG == "ruRU" and "от" or "by").." "..colorName(dmgInfo.caster,nil,dmgInfo.casterGuid))

    entry.SpellInfo.Name:SetText(spellName)
    entry.SpellInfo.Icon:SetTexture(texture)

    entry.SpellInfo.spellId = spellId
  end

  for i = #deathEvents + 1, #self.DeathRecapEntry do
    self.DeathRecapEntry[i]:Hide()
  end

  local entry = self.DeathRecapEntry[highestDmgIdx]
  -- if entry.DamageInfo.amount then
    -- entry.DamageInfo.Amount:Hide()
    -- entry.DamageInfo.AmountLarge:Show()
  -- end

  local deathEntry = self.DeathRecapEntry[1]
  local tombstoneIcon = deathEntry.tombstone
  if entry == deathEntry then
    tombstoneIcon:SetPoint("RIGHT", deathEntry.DamageInfo.AmountLarge, "LEFT", -10, 0)
  end

  self:Show()
  --DeathRecapScrollFrame
  DeathRecapContentFrame:SetSize(320,math.max(DeathRecapFrame:GetHeight(),#deathEvents*20))
  --DeathRecapScrollFrame:SetSize(320,#deathEvents*32)
  --print(#deathEvents,#deathEvents*20,DeathRecapContentFrame:GetSize())
  --DeathRecapContentFrame:SetAllPoints(DeathRecapScrollFrame)
end
--/run print(DeathRecapContentFrame:GetSize())
--/run DeathRecapContentFrame:SetSize(320,140)
function Spell_OnEnter(self)
  --print("Spell_OnEnter")
  local spellId = self.spellId
  local frame = self
  if not spellId then
    spellId = self:GetParent().spellId
    frame = self:GetParent()
  end
  if spellId then
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(GetSpellLink(spellId))
    GameTooltip:Show()
  end
end

function Amount_OnEnter(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:ClearLines()

  if self.amount then
    local valueStr = self.school and format(TEXT_MODE_A_STRING_VALUE_SCHOOL, self.amount, CombatLog_String_SchoolString(self.school)) or self.amount
    if self.critical then
      --print(self.critical)
      valueStr = valueStr .. " " .. (LANG == "ruRU" and "[КРИТ]" or "[CRIT]")
    end
    GameTooltip:AddLine(format("%s %s", valueStr, self.dmgExtraStr), 1, 0, 0, false)
  end

  if self.spellName then
    if self.caster then
      GameTooltip:AddLine(format("%s "..(LANG == "ruRU" and "от" or "by").." %s", self.spellName, colorName(self.caster,nil,self.casterGuid)), 1, 1, 1, true)
    else
      GameTooltip:AddLine(self.spellName, 1, 1, 1, true)
    end
  end

  local seconds = (DeathRecapFrame.DeathTimeStamp or 0) - self.timestamp
  if seconds > 0 then
    GameTooltip:AddLine(format("%s "..(LANG == "ruRU" and "сек перед смертью на" or "sec before death at").." %s%% "..(LANG == "ruRU" and "здоровья" or "health")..".", format("%.1F", seconds), self.hpPercent), 1, 0.824, 0, 1)
  else
    GameTooltip:AddLine(format(""..(LANG == "ruRU" and "Последний удар на" or "Killing blow at").." %s%% "..(LANG == "ruRU" and "здоровья" or "health")..".", self.hpPercent), 1, 0.824, 0, true)
  end

  GameTooltip:Show()
end

function CreateDeathRecapFrame()
  if DeathRecapFrame then
    return
  end
  
  core.After(0.1, function() print("["..GetAddOnMetadata(ADDON_NAME, "Title").."] loaded. "..GetAddOnMetadata(ADDON_NAME, "Notes").."") end)

  DeathRecapFrame = CreateFrame("Frame", "DeathRecapFrame", UIParent)
  DeathRecapFrame:SetBackdrop({
    bgFile = [[Interface\DialogFrame\UI-DialogBox-Background-Dark]],
    edgeFile = [[Interface\DialogFrame\UI-DialogBox-Border]],
    edgeSize = 8,
    insets = {left = 1, right = 1, top = 1, bottom = 1}
  })
  DeathRecapFrame:SetBackdropColor(0, 0, 1, 0.85)
  DeathRecapFrame:SetFrameStrata("HIGH")
  DeathRecapFrame:SetSize(340, 326)
  DeathRecapFrame:SetPoint("CENTER")
  DeathRecapFrame:SetMovable(true)
  DeathRecapFrame:Hide()
  DeathRecapFrame:SetScript("OnHide", function(self) self.recapID = nil end)

  tinsert(UISpecialFrames, DeathRecapFrame:GetName())
  
  -- Создаем ScrollFrame внутри родительского фрейма
  local DeathRecapScrollFrame = CreateFrame("ScrollFrame", "DeathRecapScrollFrame", DeathRecapFrame, "UIPanelScrollFrameTemplate")
  DeathRecapScrollFrame:SetSize(320, 240)  -- размер видимой области
  DeathRecapScrollFrame:SetPoint("TOPLEFT", -8, -37)
  
  -- Создаем содержимое для прокрутки
  local DeathRecapContentFrame = CreateFrame("Frame", "DeathRecapContentFrame", DeathRecapFrame)
  DeathRecapContentFrame:SetSize(320, 450)  -- размер контента больше, чем видимая область
  --DeathRecapContentFrame:SetAllPoints(DeathRecapScrollFrame)
  --DeathRecapContentFrame:SetPoint("center",DeathRecapFrame,"center")
  DeathRecapScrollFrame:SetScrollChild(DeathRecapContentFrame)

  do
    local t=0
    -- Устанавливаем ползунок в самый низ при появлении фрейма
    DeathRecapFrame:SetScript("OnShow", function()
        core.After(0.1, function()
          DeathRecapFrame:SetScript("OnUpdate", function(self, elapsed)
              -- t=t+elapsed
              -- if t<0.1 then return end
              -- t=0
              if DeathRecapScrollFrameScrollBarScrollDownButton:IsEnabled()==1 then
                --DeathRecapScrollFrameScrollBarScrollDownButton:Click()
                t=t+0,7
                DeathRecapScrollFrame:SetVerticalScroll(DeathRecapScrollFrame:GetVerticalScroll()+30-math.min(t,25))
              else
                DeathRecapFrame:SetScript("OnUpdate", nil) -- Отключаем после прокрутки
                t=0
              end
          end)
        end)
    end)
  end
  
  DeathRecapFrame.Title = DeathRecapFrame:CreateFontString("ARTWORK", nil, "GameFontNormalLarge")
  DeathRecapFrame.Title:SetPoint("TOP", 0, -9)
  DeathRecapFrame.Title:SetText(""..(LANG == "ruRU" and "Детали смерти" or "Death Recap").."")

  DeathRecapFrame.Unavailable = DeathRecapFrame:CreateFontString("ARTWORK", nil, "GameFontNormal")
  DeathRecapFrame.Unavailable:SetPoint("CENTER")
  DeathRecapFrame.Unavailable:SetText(""..(LANG == "ruRU" and "Детали смерти недоступны" or "Death Recap unavailable")..".")

  DeathRecapFrame.CloseXButton = CreateFrame("Button", "$parentCloseXButton", DeathRecapFrame, "UIPanelCloseButton")
  DeathRecapFrame.CloseXButton:SetSize(32, 32)
  DeathRecapFrame.CloseXButton:SetPoint("TOPRIGHT", 2, 1)
  DeathRecapFrame.CloseXButton:SetScript("OnClick", function(self) self:GetParent():Hide() end)

  DeathRecapFrame.DragButton = CreateFrame("Button", "$parentDragButton", DeathRecapFrame)
  DeathRecapFrame.DragButton:SetPoint("TOPLEFT", 0, 0)
  DeathRecapFrame.DragButton:SetPoint("BOTTOMRIGHT", DeathRecapFrame, "TOPRIGHT", 0, -32)
  DeathRecapFrame.DragButton:RegisterForDrag("LeftButton")
  DeathRecapFrame.DragButton:SetScript("OnDragStart", function(self) self:GetParent():StartMoving() end)
  DeathRecapFrame.DragButton:SetScript("OnDragStop", function(self) self:GetParent():StopMovingOrSizing() end)

  DeathRecapFrame.DeathRecapEntry = {}

  for i = 1, settings["NUM_DEATH_RECAP_EVENTS"] do
    local button = CreateFrame("Frame", nil, DeathRecapContentFrame)
    button:SetSize(308, 32)
    DeathRecapFrame.DeathRecapEntry[i] = button

    button.DamageInfo = CreateFrame("Button", nil, button)
    button.DamageInfo:SetPoint("TOPLEFT", 0, 0)
    button.DamageInfo:SetPoint("BOTTOMRIGHT", button, "BOTTOMLEFT", 80, 0)
    button.DamageInfo:SetScript("OnEnter", Amount_OnEnter)
    button.DamageInfo:SetScript("OnLeave", GameTooltip_Hide)

    button.DamageInfo.Amount = button.DamageInfo:CreateFontString("ARTWORK", nil, "GameFontNormalRight")
    button.DamageInfo.Amount:SetJustifyH("RIGHT")
    button.DamageInfo.Amount:SetJustifyV("CENTER")
    button.DamageInfo.Amount:SetSize(0, 32)
    button.DamageInfo.Amount:SetPoint("TOPRIGHT", 0, 0)
    button.DamageInfo.Amount:SetTextColor(0.75, 0.05, 0.05, 1)

    button.DamageInfo.AmountLarge = button.DamageInfo:CreateFontString("ARTWORK", nil, "NumberFont_Outline_Large")
    button.DamageInfo.AmountLarge:SetJustifyH("RIGHT")
    button.DamageInfo.AmountLarge:SetJustifyV("CENTER")
    button.DamageInfo.AmountLarge:SetSize(0, 32)
    button.DamageInfo.AmountLarge:SetPoint("TOPRIGHT", 0, 0)
    button.DamageInfo.AmountLarge:SetTextColor(1, 0.07, 0.07, 1)

    button.SpellInfo = CreateFrame("Button", nil, button)
    button.SpellInfo:SetPoint("TOPLEFT", button.DamageInfo, "TOPRIGHT", 16, 0)
    button.SpellInfo:SetPoint("BOTTOMRIGHT", 0, 0)
    button.SpellInfo:SetScript("OnEnter", Spell_OnEnter)
    button.SpellInfo:SetScript("OnLeave", GameTooltip_Hide)

    button.SpellInfo.FrameIcon = CreateFrame("Button", nil, button.SpellInfo)
    button.SpellInfo.FrameIcon:SetSize(34, 34)
    button.SpellInfo.FrameIcon:SetPoint("LEFT", 0, 0)

    button.SpellInfo.Icon = button.SpellInfo:CreateTexture(nil, "ARTWORK")
    button.SpellInfo.Icon:SetParent(button.SpellInfo.FrameIcon)
    button.SpellInfo.Icon:SetAllPoints(true)
    button.SpellInfo.FrameIcon:SetScript("OnEnter", Spell_OnEnter)
    button.SpellInfo.FrameIcon:SetScript("OnLeave", GameTooltip_Hide)

    button.SpellInfo.Name = button.SpellInfo:CreateFontString("ARTWORK", nil, "GameFontNormal")
    button.SpellInfo.Name:SetJustifyH("LEFT")
    button.SpellInfo.Name:SetJustifyV("BOTTOM")
    button.SpellInfo.Name:SetPoint("BOTTOMLEFT", button.SpellInfo.Icon, "RIGHT", 8, 1)
    button.SpellInfo.Name:SetPoint("TOPRIGHT", 0, 0)

    button.SpellInfo.Caster = button.SpellInfo:CreateFontString("ARTWORK", nil, "SystemFont_Shadow_Small")
    button.SpellInfo.Caster:SetJustifyH("LEFT")
    button.SpellInfo.Caster:SetJustifyV("TOP")
    button.SpellInfo.Caster:SetPoint("TOPLEFT", button.SpellInfo.Icon, "RIGHT", 8, -2)
    button.SpellInfo.Caster:SetPoint("BOTTOMRIGHT", 0, 0)
    button.SpellInfo.Caster:SetTextColor(0.5, 0.5, 0.5, 1)

    if i == 1 then
      button:SetPoint("BOTTOM", DeathRecapContentFrame, "BOTTOM", 15, -500)
      button.tombstone = button:CreateTexture(nil, "ARTWORK")
      button.tombstone:SetSize(20, 20)
      button.tombstone:SetPoint("RIGHT", button.DamageInfo.Amount, "LEFT", -10, 0)
      button.tombstone:SetTexture("Interface\\LootFrame\\LootPanel-Icon")
    else
      --button:SetPoint("BOTTOM", DeathRecapFrame.DeathRecapEntry[i - 1], "TOP", 0, 14)
      button:SetPoint("TOP", DeathRecapFrame.DeathRecapEntry[i - 1], "TOP", 0, 40)
    end
  end

  local closebutton = CreateFrame("Button", "$parentCloseButton", DeathRecapFrame, "UIPanelButtonTemplate")
  closebutton:SetSize(144, 21)
  closebutton:SetPoint("BOTTOM", 0, 15)
  closebutton:SetText(CLOSE)
  closebutton:SetScript("OnClick", function(self) self:GetParent():Hide() end)
  
  -- replace blizzard default
  StaticPopupDialogs["DeathRecapPopup"] = {
    text = DEATH_RELEASE_TIMER,
    button1 = DEATH_RELEASE,
    button2 = USE_SOULSTONE,
    button3 = ""..(LANG == "ruRU" and "Детали смерти" or "Death Recap").."",
    OnShow = function(self)
      self.timeleft = GetReleaseTimeRemaining()
      local text = HasSoulstone()
      if text then
        self.button2:SetText(text)
      elseif playerClass ~= "SHAMAN" then
        self.fixme = true
      end

      if IsActiveBattlefieldArena() then
        self.text:SetText(DEATH_RELEASE_SPECTATOR)
      elseif (self.timeleft == -1) then
        self.text:SetText(DEATH_RELEASE_NOTIMER)
      end
      if HasEvents() then
        self.button3:Enable()
        self.button3:SetScript("OnEnter", nil)
        self.button3:SetScript("OnLeave", nil)
      else
        self.button3:Disable()
        self.button3:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
          GameTooltip:SetText(""..(LANG == "ruRU" and "Детали смерти недоступны" or "Death Recap unavailable")..".")
          GameTooltip:Show()
        end)
        self.button3:SetScript("OnLeave", GameTooltip_Hide)
      end
    end,
    OnHide = function(self)
      self.button3:SetScript("OnEnter", nil)
      self.button3:SetScript("OnLeave", nil)
    end,
    OnAccept = function(self)
      if IsActiveBattlefieldArena() then
        local info = ChatTypeInfo["SYSTEM"]
        DEFAULT_CHAT_FRAME:AddMessage(ARENA_SPECTATOR, info.r, info.g, info.b, info.id)
      end
      RepopMe()
      if CannotBeResurrected() then
        return 1
      end
    end,
    OnCancel = function(self, data, reason)
      if reason == "override" then
        return
      end
      if reason == "timeout" then
        return
      end
      if reason == "clicked" then
        if HasSoulstone() then
          UseSoulstone()
        else
          RepopMe()
        end
        if CannotBeResurrected() then
          return 1
        end
      end
    end,
    OnAlt = function(self)
      core.After(0.01, function()
        if not StaticPopup_FindVisible("DeathRecapPopup") then
          StaticPopup_Show("DeathRecapPopup", GetReleaseTimeRemaining(), SECONDS)
        end
      end)
      OpenRecap(select(2, HasEvents()))
    end,
    OnUpdate = function(self, elapsed)
      if self.timeleft > 0 then
        local text = _G[self:GetName() .. "Text"]
        local timeleft = self.timeleft
        if timeleft < 60 then
          text:SetFormattedText(DEATH_RELEASE_TIMER, timeleft, SECONDS)
        else
          text:SetFormattedText(DEATH_RELEASE_TIMER, math_ceil(timeleft / 60), MINUTES)
        end
      end
      if IsFalling() and (not IsOutOfBounds()) then
        self.button1:Disable()
        self.button2:Disable()
      elseif HasSoulstone() then
        self.button1:Enable()
        self.button2:Enable()
      else
        self.button1:Enable()
        self.button2:Disable()
      end

      if self.fixme then
        self:SetWidth(320)

        self.button2:Hide()
        self.button1:ClearAllPoints()
        if self.button3:IsShown() then
          self.button1:SetPoint("BOTTOMRIGHT", self, "BOTTOM", -6, 16)
          self.button3:ClearAllPoints()
          self.button3:SetPoint("LEFT", self.button1, "RIGHT", 13, 0)
        else
          self.button1:SetPoint("BOTTOM", self, "BOTTOM", 0, 16)
        end

        self.fixme = nil
      end
    end,
    DisplayButton2 = function(self)
      return HasSoulstone()
    end,
    DisplayButton3 = function(self)
      return HasEvents()
    end,
    timeout = 0,
    whileDead = 1,
    interruptCinematic = 1,
    notClosableByLogout = 1,
    cancels = "RECOVER_CORPSE"
  }
end

core:RegisterForEvent("PLAYER_LOGIN", CreateDeathRecapFrame)

function core:HideDeathPopup()
  playerClass = select(2, UnitClass("player"))
  StaticPopup_Hide("DeathRecapPopup")
end

core:RegisterForEvent("PLAYER_ENTERING_WORLD", core.HideDeathPopup)
core:RegisterForEvent("RESURRECT_REQUEST", core.HideDeathPopup)
core:RegisterForEvent("PLAYER_ALIVE", core.HideDeathPopup)
core:RegisterForEvent("RAISED_AS_GHOUL", core.HideDeathPopup)
core:RegisterForEvent("ADDON_LOADED", function(_,addon) 
  if addon==ADDON_NAME then
    settings=DeathRecap_Settings
    if settings == nil then 
      DeathRecap_Settings = {}
      settings = DeathRecap_Settings
      settings["NUM_DEATH_RECAP_EVENTS"]=NUM_DEATH_RECAP_EVENTS
    end
  end
end)

core:RegisterForEvent("PLAYER_DEAD", function()
  print("" .. COMBATLOG_ICON_RAIDTARGET8 .. " |cFFee3322"..(LANG == "ruRU" and "Вы погибли" or "You died")..".|r |cff71d5ff|Haddon:"..ADDON_NAME.."_link|h["..(LANG == "ruRU" and "Детали смерти" or "Death Recap").."]|h|r")
  if StaticPopup_FindVisible("DEATH") then
    lastDeathEvents = (AddDeath() == true)
    StaticPopup_Hide("DEATH")
    StaticPopup_Show("DeathRecapPopup", GetReleaseTimeRemaining(), SECONDS)
  end
end)

local validEvents = {
  ENVIRONMENTAL_DAMAGE = true,
  RANGE_DAMAGE = true,
  SPELL_DAMAGE = true,
  SPELL_EXTRA_ATTACKS = true,
  SPELL_INSTAKILL = true,
  SPELL_PERIODIC_DAMAGE = true,
  SWING_DAMAGE = true
}

core:RegisterForEvent("COMBAT_LOG_EVENT_UNFILTERED", function(_, timestamp, event, srcGuid, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    if (band(dstFlags, COMBATLOG_FILTER_ME) ~= COMBATLOG_FILTER_ME) or (band(srcFlags, COMBATLOG_FILTER_ME) == COMBATLOG_FILTER_ME) or (not validEvents[event]) then
      return
    end

    --local subVal = strsub(event, 1, 5)
    local environmentalType, spellId, spellName, amount, overkill, school, resisted, blocked, absorbed, critical
    --print(subVal)
    if event == "SWING_DAMAGE" then
      amount, overkill, school, resisted, blocked, absorbed, critical = ...
    elseif event == "ENVIRONMENTAL_DAMAGE" then
      environmentalType, amount, overkill, school, resisted, blocked, absorbed = ...
    else--if subVal == "SPELL" then
      spellId, spellName, _, amount, overkill, school, resisted, blocked, absorbed, critical = ...
    end

    if not tonumber(amount) then
      return
    end

    AddEvent(timestamp, event, srcName, spellId, spellName, environmentalType, amount, overkill, school, resisted, blocked, absorbed, srcGuid, critical)
  end
)

-- chat link 11.10.24 (mrcatsoul)
do
  DEFAULT_CHAT_FRAME:HookScript("OnHyperlinkClick", function(self, link, str, button, ...)
    local linkType, arg1 = strsplit(":", link)
    if linkType == "addon" and arg1 == ADDON_NAME.."_link" then
      OpenRecap(select(2, HasEvents()))
    end
  end)
end

do
	local old = ItemRefTooltip.SetHyperlink -- we have to hook this function since the default ChatFrame code assumes that all links except for player and channel links are valid arguments for this function
	function ItemRefTooltip:SetHyperlink(link, ...)
		if link:find(ADDON_NAME.."_link") then return end
		return old(self, link, ...)
	end
end

do
  local settingsFrame = CreateFrame("Frame", "DeathRecapSettingsFrame", UIParent, "OptionsBoxTemplate")
  settingsFrame.name = GetAddOnMetadata(ADDON_NAME, "Title") 
  settingsFrame:Hide()

  local settingsTitleText = settingsFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  settingsTitleText:SetPoint("TOPLEFT", 16, -16)
  settingsTitleText:SetText(""..ADDON_NAME.." Settings")

  local editBox = CreateFrame("EditBox",nil,settingsFrame,"InputBoxTemplate") 
  editBox:SetPoint("TOPLEFT", settingsTitleText, "BOTTOMLEFT", 6, -12)
  editBox:SetAutoFocus(false)
  editBox:SetSize(30,12)
  editBox:SetFont(GameFontNormal:GetFont(), 12)
  editBox:SetText("")
  editBox:SetTextColor(1,1,1)
  
  local textFrame = CreateFrame("Button",nil,editBox) 
  local text = textFrame:CreateFontString(nil, "ARTWORK") 
  text:SetFont(GameFontNormal:GetFont(), 14)
  text:SetText("NUM_DEATH_RECAP_EVENTS")
  textFrame:SetSize(text:GetStringWidth()+50,text:GetStringHeight()) 
  textFrame:SetPoint("LEFT", editBox, "RIGHT", 3, 0)
  text:SetAllPoints(textFrame)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("BOTTOM")
  
  editBox:SetScript('OnEnterPressed', function(self) 
    local num=self:GetNumber()
    if num and num>=1 and num<=100 then
      settings["NUM_DEATH_RECAP_EVENTS"]=num
      self:SetText(num)
    else
      self:SetText(settings["NUM_DEATH_RECAP_EVENTS"])
    end
    self:ClearFocus() 
  end)
  
  editBox:SetScript('OnEditFocusLost', function(self) 
    local num=self:GetNumber()
    if num and num>=1 and num<=100 then
      settings["NUM_DEATH_RECAP_EVENTS"]=num
      self:SetText(num)
    else
      self:SetText(settings["NUM_DEATH_RECAP_EVENTS"])
    end
  end)

  editBox:SetScript('OnEscapePressed', function(self) 
    self:SetText(settings["NUM_DEATH_RECAP_EVENTS"])
    self:ClearFocus() 
  end)
  
  editBox:SetScript('OnEditFocusGained', function(self) 
    text:SetTextColor(1, 1, 1) 
  end)
  
  editBox:SetScript("OnShow", function(self) 
    textFrame:Enable()       
    text:SetTextColor(1, 1, 1) 
    if not self:HasFocus() then 
      self:SetText(settings["NUM_DEATH_RECAP_EVENTS"]) 
    end 
  end)

  -- Регистрация страницы опций
  InterfaceOptions_AddCategory(settingsFrame)
end
