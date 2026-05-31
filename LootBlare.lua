-- LootBlare 2.0.0 — Top-tier loot roll display for WoW 3.3.5a WotLK
-- Displays sorted item rolls in a unified two-panel frame:
--   Left panel: loot preview (populated by LootPreview.lua)
--   Right panel: active roll display with sorted rolls

local addonName, addon = ...
local _G, format, ipairs, pairs, tonumber, tostring, wipe = _G, format, ipairs, pairs, tonumber, tostring, wipe
local tinsert, tconcat = table.insert, table.concat
local max = math.max

-- ============================================================
-- CONSTANTS
-- ============================================================
local PREFIX = "LootBlare"
local PREFIX_SET_ROLL_TIME = "Roll time set to "
local PREFIX_SET_ROLL_CAPS = "RollCaps:"
local PREFIX_REQ_ROLL_CAPS = "ReqRollCaps"

local LB_DEBUG = false

local ROLL_PANEL_WIDTH = 165
local PREVIEW_PANEL_WIDTH = 220
local FRAME_HEIGHT = 320
local DIVIDER_WIDTH = 1

local BUTTON_WIDTH = 32
local BUTTON_COUNT = 4
local BUTTON_PADDING = 5
local FONT_NAME = "Fonts\\FRIZQT__.TTF"
local FONT_SIZE = 12
local FONT_OUTLINE = "OUTLINE"
local MAX_CACHE_SIZE = 100

local RAID_CLASS_COLORS = {
    WARRIOR     = "FFC79C6E",
    MAGE        = "FF69CCF0",
    ROGUE       = "FFFFF569",
    DRUID       = "FFFF7D0A",
    HUNTER      = "FFABD473",
    SHAMAN      = "FF0070DE",
    PRIEST      = "FFFFFFFF",
    WARLOCK     = "FF9482C9",
    PALADIN     = "FFF58CBA",
    DEATHKNIGHT = "FFC41F3B",
}

local COLORS = {
    ADDON   = "FFEDD8BB",
    DEFAULT = "FFFFFF00",
    SR      = "ffe5302d",
    MS      = "FFFFFF00",
    OS      = "FF00FF00",
    TM      = "FF00FFFF",
    OTHER   = "ffff80be",
}

-- ============================================================
-- STATE
-- ============================================================
local state = {
    rollMessages  = {},
    rollers       = {},
    isRolling     = false,
    timeElapsed   = 0,
    itemQuery     = 0.5,
    queryAttempts = 5,
    currentItem   = nil,
    masterLooter  = nil,
    mlRollDuration = 15,
    rollDuration  = 15,
    rollCap       = { sr = 100, ms = 100, os = 99, tm = 50 },
}

local discoverTooltip = CreateFrame("GameTooltip", "LootBlareTooltip", UIParent, "GameTooltipTemplate")

local formatCache = {}
local classCache  = {}
local textBuffer  = {}
local cacheSize   = 0

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|c" .. COLORS.ADDON .. "LootBlare: " .. tostring(msg) .. "|r")
end

local function GetMLName()
    local lootMethod, partyMLID, raidMLIndex = GetLootMethod()
    if lootMethod ~= "master" then return nil end
    if raidMLIndex then
        local name = GetRaidRosterInfo(raidMLIndex)
        return name
    end
    if partyMLID and partyMLID == 0 then return UnitName("player") end
    if partyMLID then return UnitName("party" .. partyMLID) end
    return nil
end

local function PlayerIsML()
    return GetMLName() == UnitName("player")
end

local function GetColoredTextByQuality(text, qualityIndex)
    local _, _, _, hex = GetItemQualityColor(qualityIndex)
    return hex .. text .. "|r"
end

local function ExtractItemLinksFromMessage(message)
    local itemLinks = {}
    for link in string.gmatch(message, "|c.-|H(item:.-)|h.-|h|r") do
        tinsert(itemLinks, link)
    end
    return itemLinks
end

local function CheckItem(link)
    discoverTooltip:SetOwner(UIParent, "ANCHOR_PRESERVE")
    discoverTooltip:SetHyperlink(link)
    local tooltipText = _G["LootBlareTooltipTextLeft1"]
    if tooltipText and tooltipText:IsVisible() then
        local name = tooltipText:GetText()
        discoverTooltip:Hide()
        return name ~= (RETRIEVING_ITEM_INFO or "")
    end
    discoverTooltip:Hide()
    return false
end

local function ResetRolls()
    wipe(state.rollMessages)
    wipe(state.rollers)
end

local function GetClassOfRoller(rollerName)
    if classCache[rollerName] then return classCache[rollerName] end
    for i = 1, GetNumRaidMembers() do
        local name, _, _, _, _, fileName = GetRaidRosterInfo(i)
        if name == rollerName then
            classCache[rollerName] = fileName
            return fileName
        end
    end
    return nil
end

-- ============================================================
-- ROLL FORMATTING & SORTING
-- ============================================================
local function SortRolls()
    table.sort(state.rollMessages, function(a, b)
        if a.minRoll == 1 and b.minRoll ~= 1 then return true
        elseif a.minRoll ~= 1 and b.minRoll == 1 then return false end
        if a.maxRoll ~= b.maxRoll then return a.maxRoll > b.maxRoll end
        if a.minRoll ~= b.minRoll then return a.minRoll > b.minRoll end
        return a.roll > b.roll
    end)
end

local function FormatRollMessage(msg)
    local cacheKey = msg.roller .. ":" .. msg.roll .. ":" .. msg.minRoll .. ":" .. msg.maxRoll .. ":" .. (msg.rollType or "")
    if formatCache[cacheKey] then return formatCache[cacheKey] end

    local classUpper = msg.class and msg.class:upper() or ""
    local classColor = RAID_CLASS_COLORS[classUpper] or "FFFFFFFF"

    local textColor
    if msg.rollType then
        if     msg.rollType == "SoftRes"  then textColor = COLORS.SR
        elseif msg.rollType == "MainSpec" then textColor = COLORS.MS
        elseif msg.rollType == "OffSpec"  then textColor = COLORS.OS
        elseif msg.rollType == "Transmog" then textColor = COLORS.TM
        else                                   textColor = COLORS.DEFAULT end
    elseif msg.maxRoll > state.rollCap.ms then  textColor = COLORS.SR
    elseif msg.maxRoll == state.rollCap.ms then textColor = COLORS.MS
    elseif msg.maxRoll == state.rollCap.os then textColor = COLORS.OS
    elseif msg.maxRoll <= state.rollCap.tm then textColor = COLORS.TM
    else                                        textColor = COLORS.DEFAULT end

    local c_class = format("|c%s%-12s|r", classColor, msg.roller)
    local c_end
    if msg.minRoll == 1 then
        -- Prefer RollFor's authoritative roll type; fall back to value-based
        -- labeling for standalone use (no RollFor sync).
        if msg.rollType then
            if     msg.rollType == "SoftRes"  then c_end = " SR"
            elseif msg.rollType == "MainSpec" then c_end = " MS"
            elseif msg.rollType == "OffSpec"  then c_end = " OS"
            elseif msg.rollType == "Transmog" then c_end = " TM"
            else   c_end = format("(%d)", msg.maxRoll) end
        elseif msg.maxRoll == state.rollCap.sr and state.rollCap.sr ~= state.rollCap.ms then c_end = " SR"
        elseif msg.maxRoll == state.rollCap.ms then c_end = " MS"
        elseif msg.maxRoll == state.rollCap.os then c_end = " OS"
        elseif msg.maxRoll == state.rollCap.tm then c_end = " TM"
        else   c_end = format("(%d)", msg.maxRoll) end
    else
        c_end = format("|cFFFF0000%d|c%s-%d|r", msg.minRoll, textColor, msg.maxRoll)
    end

    local result = format("%s|c%s%-3s%s|r", c_class, textColor, msg.roll, c_end)
    if cacheSize < MAX_CACHE_SIZE then
        formatCache[cacheKey] = result
        cacheSize = cacheSize + 1
    end
    return result
end

-- ============================================================
-- FORWARD DECLARATIONS
-- ============================================================
local itemRollFrame      -- the outer unified frame
local UpdateFrameLayout  -- called to resize the frame when preview state changes
local UpdateTextArea     -- updates the roll text area on the right panel

-- ============================================================
-- UI — SET ITEM INFO
-- ============================================================
local function SetItemInfo(rp, itemLinkArg)
    local itemName, itemLink, itemQuality, _, _, _, _, _, _, itemIcon = GetItemInfo(itemLinkArg)
    if itemName and itemQuality < 2 and not LB_DEBUG then return false end

    if not itemIcon then
        rp.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        rp.nameText:SetText("Unknown item, attempting to query...")
        return true
    end

    rp.icon:SetTexture(itemIcon)
    rp.iconButton:SetNormalTexture(itemIcon)
    rp.nameText:SetText(GetColoredTextByQuality(itemName, itemQuality))
    itemRollFrame.itemLink = itemLink
    return true
end

-- ============================================================
-- UI — UPDATE TEXT AREA (roll list on right panel)
-- ============================================================
UpdateTextArea = function(rp)
    if not rp.textArea then
        rp.textArea = rp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rp.textArea:SetFont("Interface\\AddOns\\LootBlare-wrath\\MonaspaceNeonFrozen-Regular.ttf", 12, "")
        rp.textArea:SetHeight(150)
        rp.textArea:SetPoint("TOPLEFT", rp, "TOPLEFT", 5, -70)
        rp.textArea:SetJustifyH("LEFT")
        rp.textArea:SetJustifyV("TOP")
    end

    SortRolls()
    local count = 0
    local maxMessages = #state.rollMessages
    local limit = maxMessages > 9 and 9 or maxMessages

    for i = 1, limit do
        count = count + 1
        textBuffer[count] = FormatRollMessage(state.rollMessages[i])
    end
    for i = count + 1, #textBuffer do textBuffer[i] = nil end
    rp.textArea:SetText(tconcat(textBuffer, "\n"))
end

-- ============================================================
-- UI — CREATE UNIFIED FRAME
-- ============================================================
local function CreateItemRollFrame()
    -- Outer frame (starts at roll-only width; expands when preview is active)
    local frame = CreateFrame("Frame", "ItemRollFrame", UIParent)
    frame:SetWidth(ROLL_PANEL_WIDTH)
    frame:SetHeight(FRAME_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 1)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    frame.itemLink = ""

    -- Close button (always top-right of outer frame)
    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetWidth(32)
    closeButton:SetHeight(32)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    closeButton:SetNormalTexture("Interface/Buttons/UI-Panel-MinimizeButton-Up")
    closeButton:SetPushedTexture("Interface/Buttons/UI-Panel-MinimizeButton-Down")
    closeButton:SetHighlightTexture("Interface/Buttons/UI-Panel-MinimizeButton-Highlight")
    closeButton:SetScript("OnClick", function()
        frame:Hide()
        ResetRolls()
    end)

    -- Vertical divider (hidden when preview is not active)
    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(DIVIDER_WIDTH)
    divider:SetPoint("TOPLEFT", frame, "TOPLEFT", PREVIEW_PANEL_WIDTH, -4)
    divider:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PREVIEW_PANEL_WIDTH, 4)
    divider:SetTexture(0.4, 0.4, 0.4, 0.6)
    divider:Hide()
    frame.divider = divider

    -- ========================================================
    -- RIGHT PANEL — roll display sub-frame
    -- ========================================================
    local rp = CreateFrame("Frame", nil, frame)
    rp:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    rp:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    rp:SetWidth(ROLL_PANEL_WIDTH)
    frame.rollPanel = rp

    -- Roll buttons (anchored to bottom of right panel)
    local rollButtons = {
        { text = "sr", tooltip = "Roll for Soft Reserve" },
        { text = "ms", tooltip = "Roll for Main Spec" },
        { text = "os", tooltip = "Roll for Off Spec" },
        { text = "tm", tooltip = "Roll for Transmog" },
    }

    local spacing = (ROLL_PANEL_WIDTH - (BUTTON_COUNT * BUTTON_WIDTH)) / (BUTTON_COUNT + 1)

    for i, btnData in ipairs(rollButtons) do
        local tooltip = btnData.tooltip
        local rollType = btnData.text
        local btn = CreateFrame("Button", nil, rp)
        btn:SetWidth(BUTTON_WIDTH)
        btn:SetHeight(BUTTON_WIDTH)
        btn:SetPoint("BOTTOMLEFT", rp, "BOTTOMLEFT", i * spacing + (i - 1) * BUTTON_WIDTH, BUTTON_PADDING)
        btn:SetText(string.upper(rollType))
        btn:GetFontString():SetFont(FONT_NAME, FONT_SIZE, FONT_OUTLINE)

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(btn)
        bg:SetTexture(1, 1, 1, 1)
        bg:SetVertexColor(0.2, 0.2, 0.2, 1)

        btn:SetScript("OnMouseDown", function() bg:SetVertexColor(0.6, 0.6, 0.6, 1) end)
        btn:SetScript("OnMouseUp",   function() bg:SetVertexColor(0.4, 0.4, 0.4, 1) end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip, nil, nil, nil, nil, true)
            bg:SetVertexColor(0.4, 0.4, 0.4, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            bg:SetVertexColor(0.2, 0.2, 0.2, 1)
            GameTooltip:Hide()
        end)
        btn:SetScript("OnClick", function()
            RandomRoll(1, state.rollCap[rollType])
        end)
    end

    -- Item icon (large, centred at top of right panel)
    rp.icon = rp:CreateTexture()
    rp.icon:SetWidth(40)
    rp.icon:SetHeight(40)
    rp.icon:SetPoint("TOP", rp, "TOP", 0, -10)

    rp.iconButton = CreateFrame("Button", nil, rp)
    rp.iconButton:SetWidth(40)
    rp.iconButton:SetHeight(40)
    rp.iconButton:SetPoint("TOP", rp, "TOP", 0, -10)

    -- Timer text
    rp.timerText = rp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rp.timerText:SetPoint("CENTER", rp, "TOPLEFT", 30, -32)
    rp.timerText:SetFont(FONT_NAME, 20, FONT_OUTLINE)

    -- Item name
    rp.nameText = rp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rp.nameText:SetPoint("TOP", rp.icon, "BOTTOM", 0, -2)

    -- Icon tooltip (shift-hover = compare)
    rp.iconButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(rp.iconButton, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(frame.itemLink or state.currentItem or "")
        if IsShiftKeyDown() then
            GameTooltip_ShowCompareItem()
        end
        GameTooltip:Show()
    end)
    rp.iconButton:SetScript("OnLeave", function()
        ShoppingTooltip1:Hide()
        ShoppingTooltip2:Hide()
        GameTooltip:Hide()
    end)
    rp.iconButton:HookScript("OnUpdate", function(self)
        if GameTooltip:IsOwned(rp.iconButton) then
            if IsShiftKeyDown() then
                GameTooltip_ShowCompareItem()
            else
                ShoppingTooltip1:Hide()
                ShoppingTooltip2:Hide()
            end
        end
    end)
    rp.iconButton:SetScript("OnClick", function(self, button)
        local currentLink = frame.itemLink or state.currentItem
        if not currentLink then return end
        if IsControlKeyDown() then
            DressUpItemLink(currentLink)
        elseif IsShiftKeyDown() then
            local chatEditBox = ChatFrameEditBox or ChatFrame1EditBox
            if chatEditBox and chatEditBox:IsVisible() then
                local itemName, itemLink, itemQuality = GetItemInfo(currentLink)
                if itemLink then
                    chatEditBox:Insert(
                        ITEM_QUALITY_COLORS[itemQuality].hex
                        .. "\124H" .. itemLink .. "\124h[" .. itemName .. "]\124h"
                        .. FONT_COLOR_CODE_CLOSE
                    )
                end
            end
        end
    end)

    frame:Hide()
    return frame
end

itemRollFrame = CreateItemRollFrame()

-- ============================================================
-- FRAME LAYOUT — resize based on preview state
-- ============================================================
UpdateFrameLayout = function()
    local previewActive = addon.lootPreview and addon.lootPreview.active
    if previewActive and itemRollFrame.previewPanel then
        itemRollFrame:SetWidth(PREVIEW_PANEL_WIDTH + DIVIDER_WIDTH + ROLL_PANEL_WIDTH)
        itemRollFrame.previewPanel:Show()
        itemRollFrame.divider:Show()
        -- Show the whole frame when loot drops are detected
        itemRollFrame:Show()
    else
        itemRollFrame:SetWidth(ROLL_PANEL_WIDTH)
        if itemRollFrame.previewPanel then
            itemRollFrame.previewPanel:Hide()
        end
        itemRollFrame.divider:Hide()
    end
end

-- Export so LootPreview.lua can trigger layout updates
addon.UpdateFrameLayout = UpdateFrameLayout

-- ============================================================
-- FRAME UPDATE HANDLER (OnUpdate tick)
-- ============================================================
itemRollFrame:SetScript("OnUpdate", function(self, elapsed)
    if not state.isRolling or not elapsed then return end

    state.timeElapsed = state.timeElapsed + elapsed
    state.itemQuery   = state.itemQuery - elapsed

    local rp = self.rollPanel
    local delta = state.rollDuration - state.timeElapsed
    if rp.timerText then
        rp.timerText:SetText(format("%.1f", delta > 0 and delta or 0))
    end

    if state.timeElapsed >= max(state.rollDuration, FrameShownDuration or 15) then
        rp.timerText:SetText("0.0")
        state.timeElapsed = 0
        state.itemQuery   = 1.5
        state.queryAttempts = 3
        ResetRolls()
        state.isRolling = false
        if (FrameAutoClose ~= false) and not PlayerIsML() then
            self:Hide()
        end
        return
    end

    if state.queryAttempts > 0 and state.itemQuery < 0 and state.currentItem and not CheckItem(state.currentItem) then
        state.queryAttempts = state.queryAttempts - 1
    elseif state.currentItem then
        if not SetItemInfo(self.rollPanel, state.currentItem) then
            self:Hide()
        end
        state.queryAttempts = 5
    end
end)

local function ShowRollFrame(frame, duration, item)
    state.rollDuration = duration
    state.currentItem  = item
    state.isRolling    = true
    state.timeElapsed  = 0
    SetItemInfo(frame.rollPanel, item)
    UpdateFrameLayout()
    frame:Show()
end

-- ============================================================
-- COMMUNICATION HELPERS
-- ============================================================
local function SendRollTime()
    if PlayerIsML() then
        local chan = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
        SendAddonMessage(PREFIX, PREFIX_SET_ROLL_TIME .. (FrameShownDuration or 15), chan)
    end
end

local function SendRollCaps()
    if PlayerIsML() then
        local chan = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
        local payload = PREFIX_SET_ROLL_CAPS
            .. "sr=" .. (RollCap and RollCap.sr or 100)
            .. ",ms=" .. (RollCap and RollCap.ms or 100)
            .. ",os=" .. (RollCap and RollCap.os or 99)
            .. ",tm=" .. (RollCap and RollCap.tm or 50)
        SendAddonMessage(PREFIX, payload, chan)
    end
end

-- Exported: sync runtime state from SavedVariables (called by Config.lua)
-- Exported: let Config.lua read the runtime roll caps (includes ML overrides)
function addon.GetActiveRollCaps()
    return {
        sr = state.rollCap.sr,
        ms = state.rollCap.ms,
        os = state.rollCap.os,
        tm = state.rollCap.tm,
    }
end

function addon.SyncSettings()
    if RollCap then
        for k, _ in pairs(state.rollCap) do
            state.rollCap[k] = RollCap[k] or state.rollCap[k]
        end
    end
    state.mlRollDuration = FrameShownDuration or 15
    wipe(formatCache)
    cacheSize = 0
    if PlayerIsML() then
        SendRollTime()
        SendRollCaps()
    end
end

local function RequestRollCaps()
    if GetNumPartyMembers() == 0 and GetNumRaidMembers() == 0 then return end
    local chan = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
    SendAddonMessage(PREFIX, PREFIX_REQ_ROLL_CAPS, chan)
end

local function CheckMLChanged()
    local ml = GetMLName()
    if ml == state.masterLooter then return false end
    state.masterLooter = ml
    return true
end

-- ============================================================
-- EVENT HANDLERS
-- ============================================================
local eventHandlers = {}

function eventHandlers.CHAT_MSG_LOOT(self, message)
    if not itemRollFrame:IsVisible() then return end
    local _, _, who = string.find(message, "^(%a+) receive.? loot:")
    if not who then return end

    local links = ExtractItemLinksFromMessage(message)
    if links[1] and not links[2] and itemRollFrame.itemLink == links[1] then
        ResetRolls()
        itemRollFrame:Hide()
    end
end

function eventHandlers.CHAT_MSG_SYSTEM(self, message)
    if not string.find(message, "loot master") and not (state.isRolling and string.find(message, "rolls")) then
        return
    end

    local _, _, newML = string.find(message, "(.+) is now the loot master")
    if newML then
        SendRollTime()
        SendRollCaps()
        return
    end

    if state.isRolling and string.find(message, "(%d+)") then
        local _, _, roller, roll, minRoll, maxRoll = string.find(message, "(%S+) rolls (%d+) %((%d+)%-(%d+)%)")
        if roller and roll and (state.rollers[roller] == nil or LB_DEBUG) then
            state.rollers[roller] = 1
            tinsert(state.rollMessages, {
                roller  = roller,
                roll    = tonumber(roll),
                minRoll = tonumber(minRoll),
                maxRoll = tonumber(maxRoll),
                class   = GetClassOfRoller(roller),
            })
            UpdateTextArea(itemRollFrame.rollPanel)
        end
    end
end

-- Shared: attempt to start a roll from any message containing an item link
local function TryStartRoll(message)
    if not string.find(message, "|c.-|H") then return end

    local links = ExtractItemLinksFromMessage(message)
    if links[1] and not links[2] then
        if string.find(message, "^No one has nee")
            or string.find(message, "has been sent to")
            or string.find(message, " received ") then
            return
        end
        ResetRolls()
        UpdateTextArea(itemRollFrame.rollPanel)
        state.timeElapsed = 0
        state.isRolling = true
        ShowRollFrame(itemRollFrame, state.mlRollDuration, links[1])

        -- AUTO-ROLL from chat path (covers ML who doesn't receive own AceComm)
        if addon.GetItemIntent then
            local intent = addon.GetItemIntent(links[1])
            if intent then
                local cap
                -- RollFor uses the MS threshold for SR rolls (just /roll)
                if     intent == "sr" then cap = state.rollCap.ms
                elseif intent == "ms" then cap = state.rollCap.ms
                elseif intent == "os" then cap = state.rollCap.os
                elseif intent == "tm" then cap = state.rollCap.tm
                end
                if cap then
                    RandomRoll(1, cap)
                    if addon.SetItemAutoRolled then
                        addon.SetItemAutoRolled(links[1])
                    end
                    Print("Auto-rolled " .. string.upper(intent) .. " (1-" .. cap .. ") for " .. (links[1] or "item"))
                end
            end
        end
    end
end

function eventHandlers.CHAT_MSG_RAID_WARNING(self, message)
    -- Forward to loot preview parser first
    if addon.HandleLootPreviewChat then
        addon.HandleLootPreviewChat(message)
        UpdateFrameLayout()
    end
    TryStartRoll(message)
end

-- Support RollFor / party-based roll announcements
local function HandleGroupChat(self, message)
    -- Forward to loot preview parser first
    if addon.HandleLootPreviewChat then
        addon.HandleLootPreviewChat(message)
        UpdateFrameLayout()
    end
    if string.find(message, "^Roll for ") then
        TryStartRoll(message)
        return
    end
    -- Sync timer from RollFor's countdown messages
    if state.isRolling then
        local stopIn = string.match(message, "^Stopping rolls in (%d+)")
        if stopIn then
            local left = tonumber(stopIn)
            if left then
                -- Derive actual roll duration from elapsed + remaining
                local actualDuration = state.timeElapsed + left
                if actualDuration > 0 then
                    state.rollDuration = actualDuration
                end
                state.timeElapsed = state.rollDuration - left
            end
            return
        end
        -- Single digit countdown: "2", "1"
        if string.match(message, "^%d$") then
            local left = tonumber(message)
            if left and left <= 3 then
                state.timeElapsed = state.rollDuration - left
            end
        end
    end
end

eventHandlers.CHAT_MSG_PARTY        = HandleGroupChat
eventHandlers.CHAT_MSG_PARTY_LEADER = HandleGroupChat
eventHandlers.CHAT_MSG_RAID         = HandleGroupChat
eventHandlers.CHAT_MSG_RAID_LEADER  = HandleGroupChat

function eventHandlers.CHAT_MSG_ADDON(self, prefix, message)
    if prefix ~= PREFIX then return end

    if string.find(message, PREFIX_SET_ROLL_TIME) then
        local _, _, duration = string.find(message, "Roll time set to (%d+)")
        duration = tonumber(duration)
        if duration and duration ~= state.mlRollDuration then
            state.mlRollDuration = duration
            local msg = "Roll time set to " .. state.mlRollDuration .. " seconds by Master Looter."
            if state.mlRollDuration ~= (FrameShownDuration or 15) then
                msg = msg .. " Your display time is " .. (FrameShownDuration or 15) .. " seconds."
            end
            Print(msg)
        end
        return
    end

    if string.find(message, PREFIX_SET_ROLL_CAPS) then
        if PlayerIsML() then return end
        local changed = false
        for k, v in string.gmatch(message, "(%a+)=(%d+)") do
            v = tonumber(v)
            if state.rollCap[k] and v and v >= 1 and v <= 999 then
                state.rollCap[k] = v
                if MLRollCap and MLRollCap[k] ~= v then
                    MLRollCap[k] = v
                    changed = true
                end
            end
        end
        if changed then
            wipe(formatCache)
            cacheSize = 0
            Print("Roll caps updated by Master Looter: SR=" .. state.rollCap.sr
                .. " MS=" .. state.rollCap.ms .. " OS=" .. state.rollCap.os .. " TM=" .. state.rollCap.tm)
        end
        return
    end

    if message == PREFIX_REQ_ROLL_CAPS then
        SendRollCaps()
        return
    end
end

function eventHandlers.PARTY_LOOT_METHOD_CHANGED(self)
    if not CheckMLChanged() then return end
    if PlayerIsML() then
        SendRollTime()
        SendRollCaps()
    else
        RequestRollCaps()
    end
end

function eventHandlers.PLAYER_ENTERING_WORLD(self)
    if not CheckMLChanged() then return end
    if not PlayerIsML() then RequestRollCaps() end
end

function eventHandlers.PARTY_MEMBERS_CHANGED(self)
    if GetNumPartyMembers() == 0 and GetNumRaidMembers() == 0 then
        for k, _ in pairs(state.rollCap) do
            state.rollCap[k] = RollCap and RollCap[k] or state.rollCap[k]
        end
        wipe(formatCache)
        cacheSize = 0
    end
end

function eventHandlers.ADDON_LOADED(self, loadedAddon)
    if loadedAddon ~= "LootBlare-wrath" then return end

    -- Initialize saved variables
    if FrameShownDuration == nil then FrameShownDuration = 15 end
    if FrameAutoClose     == nil then FrameAutoClose     = true end
    if RollCap            == nil then RollCap = { sr = 100, ms = 100, os = 99, tm = 50 } end
    -- Migrate: old SR default was 101, RollFor uses 100 (same as MS)
    if RollCap.sr == 101 then RollCap.sr = 100 end
    -- Sanitize: clamp any corrupt/out-of-range caps to defaults
    local capDefaults = { sr = 100, ms = 100, os = 99, tm = 50 }
    for k, def in pairs(capDefaults) do
        local v = RollCap[k]
        if type(v) ~= "number" or v < 1 or v > 999 then
            RollCap[k] = def
        end
    end
    if MLRollCap          == nil then MLRollCap = {} end
    if LootBlareMinimap   == nil then LootBlareMinimap = {} end

    state.mlRollDuration = FrameShownDuration
    for k, _ in pairs(state.rollCap) do
        state.rollCap[k] = RollCap[k] or state.rollCap[k]
    end

    -- ====================================================
    -- Create loot preview panel (left side)
    -- LootPreview.lua has loaded by now; guard just in case.
    -- ====================================================
    if addon.CreateLootPreview then
        itemRollFrame.previewPanel = addon.CreateLootPreview(itemRollFrame)
        itemRollFrame.previewPanel:Hide()  -- hidden until loot drops
    end

    -- ====================================================
    -- Register RollFor sync callbacks
    -- RollForSync.lua has loaded by now; guard just in case.
    -- ====================================================
    if addon.RegisterRFCallback then
        -- RF_START: a new roll begins — drive the right panel
        addon.RegisterRFCallback("RF_START", function(payload)
            if not payload or not payload.link then return end
            ResetRolls()
            UpdateTextArea(itemRollFrame.rollPanel)
            state.timeElapsed = 0
            state.isRolling = true
            -- Use payload thresholds
            if payload.ms      then state.rollCap.ms = payload.ms end
            if payload.os_roll then state.rollCap.os = payload.os_roll end
            wipe(formatCache)
            cacheSize = 0
            local duration = payload.seconds or state.mlRollDuration
            ShowRollFrame(itemRollFrame, duration, payload.link)

            -- AUTO-ROLL: if the player pre-selected an intent for this item, roll immediately
            if addon.GetItemIntent then
                local intent = addon.GetItemIntent(payload.link)
                if intent then
                    local cap
                    -- RollFor uses the MS threshold for SR rolls (just /roll)
                    if     intent == "sr" then cap = state.rollCap.ms
                    elseif intent == "ms" then cap = state.rollCap.ms
                    elseif intent == "os" then cap = state.rollCap.os
                    elseif intent == "tm" then cap = state.rollCap.tm
                    end
                    if cap then
                        RandomRoll(1, cap)
                        if addon.SetItemAutoRolled then
                            addon.SetItemAutoRolled(payload.link)
                        end
                        Print("Auto-rolled " .. string.upper(intent) .. " (1-" .. cap .. ") for " .. (payload.link or "item"))
                    end
                end
            end
        end)

        -- RF_ROLL: a player rolled (supplements CHAT_MSG_SYSTEM parsing)
        addon.RegisterRFCallback("RF_ROLL", function(payload)
            if not payload or not payload.player_name or not payload.roll then return end
            if state.rollers[payload.player_name] then return end  -- already have this roll
            state.rollers[payload.player_name] = 1
            local maxRoll
            if     payload.roll_type == "MainSpec"  then maxRoll = state.rollCap.ms
            elseif payload.roll_type == "OffSpec"   then maxRoll = state.rollCap.os
            elseif payload.roll_type == "Transmog"  then maxRoll = state.rollCap.tm
            else                                         maxRoll = state.rollCap.ms end
            tinsert(state.rollMessages, {
                roller   = payload.player_name,
                roll     = payload.roll,
                minRoll  = 1,
                maxRoll  = maxRoll,
                rollType = payload.roll_type,  -- authoritative type from RollFor
                class    = payload.player_class or GetClassOfRoller(payload.player_name),
            })
            UpdateTextArea(itemRollFrame.rollPanel)
        end)

        -- RF_TICK: ML's authoritative timer sync
        addon.RegisterRFCallback("RF_TICK", function(payload)
            if payload and payload.seconds_left and state.isRolling then
                state.timeElapsed = state.rollDuration - payload.seconds_left
            end
        end)

        -- RF_FINISH: roll is done (let the existing timer handle display)
        addon.RegisterRFCallback("RF_FINISH", function()
            -- no-op — the OnUpdate timer handles frame lifetime
        end)

        -- RF_CANCEL: roll was canceled by ML
        addon.RegisterRFCallback("RF_CANCEL", function()
            state.isRolling = false
            ResetRolls()
            UpdateTextArea(itemRollFrame.rollPanel)
            if itemRollFrame.rollPanel and itemRollFrame.rollPanel.timerText then
                itemRollFrame.rollPanel.timerText:SetText("")
            end
        end)
    end

    -- ====================================================
    -- LibDataBroker / minimap icon
    -- ====================================================
    if LibStub then
        local ldb  = LibStub("LibDataBroker-1.1", true)
        local icon = LibStub("LibDBIcon-1.0", true)
        if ldb and icon then
            local dataObj = ldb:NewDataObject("LootBlare", {
                type  = "launcher",
                icon  = "Interface\\Icons\\INV_Misc_QuestionMark",
                label = "LootBlare",
                OnClick = function(_, button)
                    if button == "LeftButton" then
                        if itemRollFrame:IsShown() then
                            itemRollFrame:Hide()
                        else
                            UpdateFrameLayout()
                            itemRollFrame:Show()
                        end
                    elseif button == "RightButton" then
                        InterfaceOptionsFrame_OpenToCategory("LootBlare")
                        InterfaceOptionsFrame_OpenToCategory("LootBlare")
                    end
                end,
                OnTooltipShow = function(tooltip)
                    tooltip:AddLine("LootBlare")
                    tooltip:AddLine("Left-click to toggle roll frame", 0.8, 0.8, 0.8, true)
                    tooltip:AddLine("Right-click for options", 0.8, 0.8, 0.8, true)
                end,
            })
            icon:Register("LootBlare", dataObj, LootBlareMinimap)
        end
    end
end

-- ============================================================
-- EVENT REGISTRATION
-- ============================================================
itemRollFrame:RegisterEvent("ADDON_LOADED")
itemRollFrame:RegisterEvent("CHAT_MSG_SYSTEM")
itemRollFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
itemRollFrame:RegisterEvent("CHAT_MSG_ADDON")
itemRollFrame:RegisterEvent("CHAT_MSG_LOOT")
itemRollFrame:RegisterEvent("CHAT_MSG_PARTY")
itemRollFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
itemRollFrame:RegisterEvent("CHAT_MSG_RAID")
itemRollFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
itemRollFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
itemRollFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
itemRollFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
itemRollFrame:SetScript("OnEvent", function(self, event, ...)
    if eventHandlers[event] then
        eventHandlers[event](self, ...)
    end
end)

-- ============================================================
-- SLASH COMMANDS
-- ============================================================
SLASH_LOOTBLARE1 = "/lootblare"
SLASH_LOOTBLARE2 = "/lb"
SlashCmdList["LOOTBLARE"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "help" or msg == "" then
        Print("LootBlare " .. (GetAddOnMetadata("LootBlare-wrath", "Version") or "2.0.0") .. " — displays sorted item rolls.")
        Print("Commands: /lb time <seconds> | /lb autoclose on/off | /lb settings | /lb debug")
        Print("Commands: /lb sr <number> | /lb ms <number> | /lb os <number> | /lb tm <number>")
        return
    end
    if msg == "debug" then
        LB_DEBUG = not LB_DEBUG
        Print("Debug mode " .. (LB_DEBUG and "ON" or "OFF") .. " — quality filter " .. (LB_DEBUG and "bypassed" or "active"))
        return
    end
    if msg == "settings" then
        Print("Duration: " .. (FrameShownDuration or 15) .. "s | Auto-close: " .. ((FrameAutoClose ~= false) and "on" or "off"))
        Print("SR roll cap: " .. (RollCap and RollCap.sr or 100))
        Print("MS roll cap: " .. (RollCap and RollCap.ms or 100))
        Print("OS roll cap: " .. (RollCap and RollCap.os or 99))
        Print("TM roll cap: " .. (RollCap and RollCap.tm or 50))
        return
    end
    if string.find(msg, "time") then
        local _, _, newDuration = string.find(msg, "time (%d+)")
        newDuration = tonumber(newDuration)
        if newDuration and newDuration > 0 then
            FrameShownDuration = newDuration
            Print("Roll time set to " .. newDuration .. " seconds.")
            if PlayerIsML() then SendRollTime() end
            return
        end
        Print("Invalid duration. Enter a number > 0.")
        return
    end
    if string.find(msg, "autoclose") then
        local _, _, autoClose = string.find(msg, "autoclose (%a+)")
        if autoClose == "on"  or autoClose == "true"  then FrameAutoClose = true;  Print("Auto-close enabled.");  return end
        if autoClose == "off" or autoClose == "false" then FrameAutoClose = false; Print("Auto-close disabled."); return end
        Print("Invalid option. Use 'on' or 'off'.")
        return
    end
    if RollCap then
        for k, _ in pairs(RollCap) do
            if string.find(msg, k) then
                local _, _, newRollCap = string.find(msg, k .. " (%d+)")
                newRollCap = tonumber(newRollCap)
                if not newRollCap or newRollCap < 1 or newRollCap > 999 then
                    Print("Roll cap must be between 1 and 999.")
                    return
                end
                RollCap[k] = newRollCap
                state.rollCap[k] = newRollCap
                wipe(formatCache)
                cacheSize = 0
                Print(string.upper(k) .. " roll cap set to " .. newRollCap)
                SendRollCaps()
                return
            end
        end
    end
    if msg == "clear" then
        if addon.ClearLootPreview then addon.ClearLootPreview() end
        if addon.UpdateFrameLayout then addon.UpdateFrameLayout() end
        Print("Loot preview cleared.")
        return
    end
    if msg == "sync" then
        Print("RollFor sync: " .. (addon.rfSyncActive and "|cFF00FF00active|r" or "|cFFFF0000inactive|r"))
        local n = addon.lootPreview and #addon.lootPreview.items or 0
        Print("Loot preview: " .. n .. " items tracked")
        return
    end
    Print("Invalid command. Type /lb help for commands.")
end
