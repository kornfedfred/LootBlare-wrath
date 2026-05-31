-- LootBlare Configuration Panel
-- Native Blizzard Interface Options — no external libraries required.

local _, addon = ...

-- ============================================================
-- CREATE PANEL
-- ============================================================
local panel = CreateFrame("Frame", "LootBlareOptionsPanel", UIParent)
panel.name = "LootBlare"

-- Title
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("LootBlare v" .. (GetAddOnMetadata("LootBlare-wrath", "Version") or "2.0.0"))

-- Description
local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
desc:SetText("Configure how loot rolls are displayed and behave.")

-- ============================================================
-- FRAME DURATION SLIDER
-- ============================================================
local durationLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
durationLabel:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
durationLabel:SetText("Frame Duration")

local durationSlider = CreateFrame("Slider", "LootBlareDurationSlider", panel, "OptionsSliderTemplate")
durationSlider:SetPoint("TOPLEFT", durationLabel, "BOTTOMLEFT", 0, -16)
durationSlider:SetWidth(200)
durationSlider:SetHeight(16)
durationSlider:SetMinMaxValues(5, 60)
durationSlider:SetValueStep(1)
durationSlider:SetOrientation("HORIZONTAL")

_G["LootBlareDurationSliderText"]:SetText("")
_G["LootBlareDurationSliderLow"]:SetText("5s")
_G["LootBlareDurationSliderHigh"]:SetText("60s")

local durationValue = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
durationValue:SetPoint("LEFT", durationSlider, "RIGHT", 10, 0)
durationValue:SetText("15s")

durationSlider:SetScript("OnValueChanged", function(self)
    durationValue:SetText(math.floor(self:GetValue() + 0.5) .. "s")
end)

-- ============================================================
-- AUTO-CLOSE CHECKBOX
-- ============================================================
local autoCloseCheck = CreateFrame("CheckButton", "LootBlareAutoCloseCheck", panel, "UICheckButtonTemplate")
autoCloseCheck:SetPoint("TOPLEFT", durationSlider, "BOTTOMLEFT", -2, -16)
_G["LootBlareAutoCloseCheckText"]:SetText("Auto-close frame after duration expires (non-ML)")

-- ============================================================
-- ROLL CAPS SECTION
-- ============================================================
local capsHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
capsHeader:SetPoint("TOPLEFT", autoCloseCheck, "BOTTOMLEFT", 2, -20)
capsHeader:SetText("Roll Caps")

local capsDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
capsDesc:SetPoint("TOPLEFT", capsHeader, "BOTTOMLEFT", 0, -4)
capsDesc:SetText("Maximum roll values for each category.")

-- Helper to create a labeled numeric edit box, anchored relative to a reference element
local function CreateCapRow(anchorTo, labelText, name)
    local row = CreateFrame("Frame", nil, panel)
    row:SetHeight(24)
    row:SetWidth(300)
    row:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -8)

    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetWidth(130)
    label:SetJustifyH("LEFT")
    label:SetText(labelText)

    local edit = CreateFrame("EditBox", name, row)
    edit:SetPoint("LEFT", label, "RIGHT", 8, 0)
    edit:SetWidth(50)
    edit:SetHeight(22)
    edit:SetFontObject("ChatFontNormal")
    edit:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    edit:SetBackdropColor(0, 0, 0, 0.5)
    edit:SetTextInsets(6, 6, 0, 0)
    edit:SetAutoFocus(false)
    edit:SetNumeric(true)
    edit:SetMaxLetters(4)
    edit:SetScript("OnEditFocusGained", function(self) self:SetBackdropColor(0.1, 0.1, 0.1, 0.8) end)
    edit:SetScript("OnEditFocusLost",   function(self) self:SetBackdropColor(0, 0, 0, 0.5) end)
    edit:SetScript("OnEnterPressed",    function(self) self:ClearFocus() end)
    edit:SetScript("OnEscapePressed",   function(self) self:ClearFocus() end)

    return row, edit
end

local srRow, srEdit = CreateCapRow(capsDesc,  "SR (Soft Reserve):", "LootBlareSREdit")
local msRow, msEdit = CreateCapRow(srRow,     "MS (Main Spec):",    "LootBlareMSEdit")
local osRow, osEdit = CreateCapRow(msRow,     "OS (Off Spec):",     "LootBlareOSEdit")
local tmRow, tmEdit = CreateCapRow(osRow,     "TM (Transmog):",     "LootBlareTMEdit")

-- ============================================================
-- OK / CANCEL / DEFAULT / REFRESH
-- ============================================================
panel.okay = function()
    FrameShownDuration = math.floor(durationSlider:GetValue() + 0.5)
    FrameAutoClose = autoCloseCheck:GetChecked() and true or false

    if not RollCap then RollCap = { sr = 101, ms = 100, os = 99, tm = 50 } end
    RollCap.sr = tonumber(srEdit:GetText()) or RollCap.sr or 101
    RollCap.ms = tonumber(msEdit:GetText()) or RollCap.ms or 100
    RollCap.os = tonumber(osEdit:GetText()) or RollCap.os or 99
    RollCap.tm = tonumber(tmEdit:GetText()) or RollCap.tm or 50

    -- Sync runtime state and broadcast if ML
    if addon.SyncSettings then addon.SyncSettings() end
end

panel.cancel = function()
    panel.refresh()
end

panel.default = function()
    FrameShownDuration = 15
    FrameAutoClose = true
    RollCap = { sr = 101, ms = 100, os = 99, tm = 50 }
    if addon.SyncSettings then addon.SyncSettings() end
    panel.refresh()
end

panel.refresh = function()
    durationSlider:SetValue(FrameShownDuration or 15)
    durationValue:SetText((FrameShownDuration or 15) .. "s")
    autoCloseCheck:SetChecked(FrameAutoClose ~= false)

    if not RollCap then RollCap = { sr = 101, ms = 100, os = 99, tm = 50 } end
    srEdit:SetText(RollCap.sr or 101)
    msEdit:SetText(RollCap.ms or 100)
    osEdit:SetText(RollCap.os or 99)
    tmEdit:SetText(RollCap.tm or 50)
end

-- ============================================================
-- REGISTER WITH BLIZZARD
-- ============================================================
InterfaceOptions_AddCategory(panel)
