-- LootPreview — Left panel showing all dropped loot with intent buttons.
-- Parses RollFor chat announces and tracks item status via RF_* callbacks.

local _, addon = ...

local INTENT_LABELS = { "sr", "ms", "os", "tm" }
local INTENT_DISPLAY = { sr = "SR", ms = "MS", os = "OS", tm = "TM" }
local INTENT_COLORS = {
    sr = { r = 0.90, g = 0.19, b = 0.18 },
    ms = { r = 1.00, g = 1.00, b = 0.00 },
    os = { r = 0.00, g = 1.00, b = 0.00 },
    tm = { r = 0.00, g = 1.00, b = 1.00 },
}

local ROW_HEIGHT = 46
local ICON_SIZE = 28
local MAX_VISIBLE = 6
local PANEL_WIDTH = 220
local INTENT_BTN_W = 28
local INTENT_BTN_H = 14

-- ============================================================
-- DATA MODEL
-- ============================================================
addon.lootPreview = addon.lootPreview or { items = {}, active = false }
local preview = addon.lootPreview

local collecting = false
local collectTimer = 0
local timerFrame  -- forward declare

-- ============================================================
-- HELPERS
-- ============================================================
local function FindItemByLink(link)
    if not link then return nil, nil end
    local searchId = tonumber(string.match(link, "item:(%d+)"))
    if not searchId then return nil, nil end
    for i, entry in ipairs(preview.items) do
        local entryId = tonumber(string.match(entry.link, "item:(%d+)"))
        if entryId == searchId then return entry, i end
    end
    return nil, nil
end

local function StripColorCodes(text)
    local s = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    return s
end

-- ============================================================
-- CHAT PARSING
-- ============================================================
local function ParseItemLine(message)
    local num, rest = string.match(message, "^(%d+)%.%s*(.+)")
    if not num or not rest then return nil end

    local fullLink = string.match(rest, "(|c%x+|Hitem:.-%|h%[.-%]|h|r)")
    if not fullLink then return nil end

    local count = tonumber(string.match(rest, "^(%d+)x")) or 1
    local hr = string.find(rest, "%(HR%)") ~= nil
    local sr = string.match(rest, "%(SR by (.-)%)")
    if sr then sr = StripColorCodes(sr) end

    local itemName, _, itemQuality, _, _, _, _, _, _, itemTexture = GetItemInfo(fullLink)

    return {
        link = fullLink,
        icon = itemTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
        quality = itemQuality or 0,
        name = itemName or "Unknown",
        sr = sr,
        hr = hr,
        count = count,
        status = "pending",
        winner = nil,
        intent = nil,
        autoRolled = false,
    }
end

local function IsDropHeader(message)
    local plain = StripColorCodes(message)
    -- Match RollFor format: "Bossname dropped N items:" or "Bossname dropped N item:"
    if string.find(plain, "dropped %d+ items?%s*:") then
        return true
    end
    return false
end

-- Parse follow-up SR/no-SR announcements: "[Item] has no Soft-Res." or "[Item] is soft-ressed by X"
local function ParseSRStatus(message)
    -- "[Item] has no Soft-Res."
    local noSrLink = string.match(message, "(|c%x+|Hitem:.-%|h%[.-%]|h|r) has no Soft%-Res")
    if noSrLink then
        local entry = FindItemByLink(noSrLink)
        if entry and not entry.sr then
            entry.noSr = true
        end
        return true
    end
    -- "[Item] is soft-ressed by PlayerA, PlayerB" (sometimes without color codes)
    local srLink, srNames = string.match(message, "(|c%x+|Hitem:.-%|h%[.-%]|h|r) is soft%-ressed by (.+)")
    if srLink and srNames then
        local entry = FindItemByLink(srLink)
        if entry then
            entry.sr = StripColorCodes(srNames)
            -- Check if current player is among the SR names
            local me = UnitName("player")
            if me and string.find(entry.sr, me, 1, true) then
                entry.playerSR = true
                entry.intent = "sr"  -- auto-select SR intent
            end
        end
        return true
    end
    return false
end

function addon.HandleLootPreviewChat(message)
    if IsDropHeader(message) then
        wipe(preview.items)
        preview.active = true
        collecting = true
        collectTimer = 3
        if timerFrame then timerFrame:Show() end
        if addon.RefreshLootPreview then addon.RefreshLootPreview() end
        return true
    end

    if collecting then
        local entry = ParseItemLine(message)
        if entry then
            -- Check if current player is in the SR annotation
            if entry.sr then
                local me = UnitName("player")
                if me and string.find(entry.sr, me, 1, true) then
                    entry.playerSR = true
                    entry.intent = "sr"  -- auto-select SR intent
                end
            end
            table.insert(preview.items, entry)
            collectTimer = 3
            if timerFrame then timerFrame:Show() end
            if addon.RefreshLootPreview then addon.RefreshLootPreview() end
            return true
        end
    end

    -- SR status messages can arrive after the item list
    if #preview.items > 0 then
        if ParseSRStatus(message) then
            if addon.RefreshLootPreview then addon.RefreshLootPreview() end
            return true
        end
    end

    return false
end

-- ============================================================
-- RF_* CALLBACKS
-- ============================================================
if addon.RegisterRFCallback then
    addon.RegisterRFCallback("RF_START", function(payload)
        if not payload or not payload.link then return end
        local entry = FindItemByLink(payload.link)
        if entry then
            entry.status = "rolling"
            -- Extract SR info from AceComm payload
            if payload.strategy == "SoftResRoll" and payload.rolls then
                local names = {}
                local me = UnitName("player")
                for _, roll in ipairs(payload.rolls) do
                    local rname = roll.name or roll.player_name  -- RollingPlayer uses .name; RF_ROLL uses .player_name
                    if rname then
                        table.insert(names, rname)
                        if me and rname == me then
                            entry.playerSR = true
                            entry.intent = "sr"  -- auto-select SR intent
                        end
                    end
                end
                if #names > 0 and not entry.sr then
                    entry.sr = table.concat(names, ", ")
                end
            end
            if addon.RefreshLootPreview then addon.RefreshLootPreview() end
        end
    end)

    addon.RegisterRFCallback("RF_WIN", function(payload)
        if not payload or not payload.link then return end
        local entry = FindItemByLink(payload.link)
        if entry then
            entry.status = "won"
            entry.winner = payload.name
            if addon.RefreshLootPreview then addon.RefreshLootPreview() end
        end
    end)

    addon.RegisterRFCallback("RF_FINISH", function()
        for _, entry in ipairs(preview.items) do
            if entry.status == "rolling" then
                if not entry.winner then entry.status = "pending" end
            end
        end
        if addon.RefreshLootPreview then addon.RefreshLootPreview() end
    end)

    addon.RegisterRFCallback("RF_CANCEL", function()
        for _, entry in ipairs(preview.items) do
            if entry.status == "rolling" then
                entry.status = "canceled"
            end
        end
        if addon.RefreshLootPreview then addon.RefreshLootPreview() end
    end)
end

-- ============================================================
-- PUBLIC API
-- ============================================================
function addon.GetItemIntent(itemLink)
    local entry = FindItemByLink(itemLink)
    return entry and entry.intent or nil
end

function addon.IsItemAutoRolled(itemLink)
    local entry = FindItemByLink(itemLink)
    return entry and entry.autoRolled or false
end

function addon.SetItemAutoRolled(itemLink)
    local entry = FindItemByLink(itemLink)
    if entry then
        entry.autoRolled = true
        if addon.RefreshLootPreview then addon.RefreshLootPreview() end
    end
end

function addon.ClearLootPreview()
    wipe(preview.items)
    preview.active = false
    collecting = false
    collectTimer = 0
    if addon.RefreshLootPreview then addon.RefreshLootPreview() end
end

-- ============================================================
-- UI
-- ============================================================
local rows = {}
local scrollOffset = 0
local previewFrame

-- Create a small intent button
local function CreateIntentButton(parent, intentKey, rowIndex)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(INTENT_BTN_W)
    btn:SetHeight(INTENT_BTN_H)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
    btn.bg = bg

    local label = btn:CreateFontString(nil, "OVERLAY")
    label:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    label:SetPoint("CENTER", btn, "CENTER", 0, 0)
    label:SetText(INTENT_DISPLAY[intentKey])
    btn.label = label

    btn:SetScript("OnClick", function()
        local idx = rowIndex + scrollOffset
        local entry = preview.items[idx]
        if not entry or entry.hr then return end

        if entry.intent == intentKey then
            entry.intent = nil  -- deselect
        else
            entry.intent = intentKey
        end
        if addon.RefreshLootPreview then addon.RefreshLootPreview() end
    end)

    btn:SetScript("OnEnter", function(self)
        bg:SetVertexColor(0.3, 0.3, 0.3, 0.9)
    end)
    btn:SetScript("OnLeave", function(self)
        -- Refresh will set the correct color
        if addon.RefreshLootPreview then addon.RefreshLootPreview() end
    end)

    return btn
end

function addon.CreateLootPreview(parent)
    previewFrame = CreateFrame("Frame", "LootBlarePreviewPanel", parent)
    previewFrame:SetWidth(PANEL_WIDTH)
    previewFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    previewFrame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)

    -- Header
    local header = previewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", previewFrame, "TOPLEFT", 8, -8)
    header:SetText("Dropped Loot")

    -- Row container
    local container = CreateFrame("Frame", nil, previewFrame)
    container:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -4, -4)
    container:SetPoint("BOTTOMRIGHT", previewFrame, "BOTTOMRIGHT", 0, 4)

    for i = 1, MAX_VISIBLE do
        local row = CreateFrame("Frame", nil, container)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)

        -- Rolling highlight background
        local rollBg = row:CreateTexture(nil, "BACKGROUND")
        rollBg:SetAllPoints(row)
        rollBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
        rollBg:SetVertexColor(0.0, 0.5, 0.0, 0.0)
        row.rollBg = rollBg

        -- Item icon (clickable for tooltip)
        local icon = CreateFrame("Button", nil, row)
        icon:SetWidth(ICON_SIZE)
        icon:SetHeight(ICON_SIZE)
        icon:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -2)
        row.icon = icon

        local iconTex = icon:CreateTexture(nil, "ARTWORK")
        iconTex:SetAllPoints(icon)
        row.iconTex = iconTex

        icon:SetScript("OnEnter", function(self)
            local idx = i + scrollOffset
            local entry = preview.items[idx]
            if entry and entry.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(entry.link)
                if IsShiftKeyDown() then
                    GameTooltip_ShowCompareItem()
                end
                GameTooltip:Show()
            end
        end)
        icon:SetScript("OnLeave", function()
            ShoppingTooltip1:Hide()
            ShoppingTooltip2:Hide()
            GameTooltip:Hide()
        end)
        icon:HookScript("OnUpdate", function(self)
            local idx = i + scrollOffset
            local entry = preview.items[idx]
            if entry and entry.link and GameTooltip:IsOwned(self) then
                if IsShiftKeyDown() then
                    GameTooltip_ShowCompareItem()
                else
                    ShoppingTooltip1:Hide()
                    ShoppingTooltip2:Hide()
                end
            end
        end)

        -- Item name (top line)
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 4, 0)
        name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        row.nameText = name

        -- Status text (below name, right-aligned)
        local status = row:CreateFontString(nil, "OVERLAY")
        status:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        status:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -2)
        status:SetJustifyH("RIGHT")
        row.statusText = status

        -- Intent buttons row (below icon/name)
        local btnRow = CreateFrame("Frame", nil, row)
        btnRow:SetHeight(INTENT_BTN_H)
        btnRow:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 4)
        btnRow:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 4)
        row.btnRow = btnRow

        row.intentBtns = {}
        for j, key in ipairs(INTENT_LABELS) do
            local btn = CreateIntentButton(btnRow, key, i)
            btn:SetPoint("LEFT", btnRow, "LEFT", (j - 1) * (INTENT_BTN_W + 3), 0)
            row.intentBtns[key] = btn
        end

        -- Auto-rolled indicator (after buttons)
        local autoLabel = btnRow:CreateFontString(nil, "OVERLAY")
        autoLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
        autoLabel:SetPoint("LEFT", btnRow, "LEFT", (#INTENT_LABELS) * (INTENT_BTN_W + 3) + 4, 0)
        autoLabel:SetTextColor(0.5, 1.0, 0.5)
        autoLabel:SetText("")
        row.autoLabel = autoLabel

        row:Hide()
        rows[i] = row
    end

    -- Mousewheel scrolling
    container:EnableMouseWheel(true)
    container:SetScript("OnMouseWheel", function(self, delta)
        local maxOffset = math.max(0, #preview.items - MAX_VISIBLE)
        scrollOffset = math.max(0, math.min(scrollOffset - delta, maxOffset))
        if addon.RefreshLootPreview then addon.RefreshLootPreview() end
    end)

    return previewFrame
end

-- ============================================================
-- REFRESH
-- ============================================================
function addon.RefreshLootPreview()
    if not previewFrame then return end

    for i = 1, MAX_VISIBLE do
        local row = rows[i]
        local idx = i + scrollOffset
        local entry = preview.items[idx]

        if entry then
            -- Icon
            row.iconTex:SetTexture(entry.icon)

            -- Name (quality-colored, with count)
            local displayName = entry.name or "Unknown"
            if entry.count and entry.count > 1 then
                displayName = entry.count .. "x " .. displayName
            end
            local r, g, b = GetItemQualityColor(entry.quality or 0)
            row.nameText:SetText(displayName)
            row.nameText:SetTextColor(r, g, b)

            -- Status text (top-right)
            if entry.hr then
                row.statusText:SetText("HR")
                row.statusText:SetTextColor(0.8, 0.2, 0.2)
            elseif entry.status == "rolling" then
                if entry.sr then
                    row.statusText:SetText("SR ROLL")
                else
                    row.statusText:SetText("ROLLING")
                end
                row.statusText:SetTextColor(0.0, 1.0, 0.0)
            elseif entry.status == "won" and entry.winner then
                row.statusText:SetText(entry.winner)
                row.statusText:SetTextColor(0.2, 0.8, 0.2)
            elseif entry.status == "canceled" then
                row.statusText:SetText("X")
                row.statusText:SetTextColor(0.8, 0.2, 0.2)
            elseif entry.playerSR then
                -- Current player has this item SR'd — prominent highlight
                row.statusText:SetText("YOUR SR")
                row.statusText:SetTextColor(0.9, 0.19, 0.18)
            elseif entry.sr then
                row.statusText:SetText("SR: " .. entry.sr)
                row.statusText:SetTextColor(0.9, 0.5, 0.2)
            elseif entry.noSr then
                row.statusText:SetText("No SR")
                row.statusText:SetTextColor(0.5, 0.5, 0.5)
            else
                row.statusText:SetText("")
            end

            -- Rolling highlight — brighter for player's own SR
            if entry.status == "rolling" and entry.playerSR then
                row.rollBg:SetVertexColor(0.4, 0.1, 0.0, 0.4)
            elseif entry.status == "rolling" then
                row.rollBg:SetVertexColor(0.0, 0.4, 0.0, 0.35)
            else
                row.rollBg:SetVertexColor(0.0, 0.0, 0.0, 0.0)
            end

            -- Intent buttons
            for _, key in ipairs(INTENT_LABELS) do
                local btn = row.intentBtns[key]
                local ic = INTENT_COLORS[key]
                if entry.hr or entry.status == "won" then
                    -- Disable buttons for HR or won items
                    btn:Disable()
                    btn.bg:SetVertexColor(0.1, 0.1, 0.1, 0.3)
                    btn.label:SetTextColor(0.3, 0.3, 0.3)
                elseif entry.intent == key then
                    -- This intent is selected — highlight it
                    btn:Enable()
                    btn.bg:SetVertexColor(ic.r * 0.4, ic.g * 0.4, ic.b * 0.4, 0.9)
                    btn.label:SetTextColor(ic.r, ic.g, ic.b)
                else
                    -- Not selected
                    btn:Enable()
                    btn.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
                    btn.label:SetTextColor(0.6, 0.6, 0.6)
                end
            end

            -- Auto-rolled label
            if entry.autoRolled then
                row.autoLabel:SetText("Auto!")
            else
                row.autoLabel:SetText("")
            end

            row:Show()
        else
            row:Hide()
        end
    end
end

-- ============================================================
-- COLLECT TIMER
-- ============================================================
timerFrame = CreateFrame("Frame")
timerFrame:Hide()  -- only runs when collecting
timerFrame:SetScript("OnUpdate", function(self, elapsed)
    collectTimer = collectTimer - elapsed
    if collectTimer <= 0 then
        collecting = false
        self:Hide()
    end
end)
