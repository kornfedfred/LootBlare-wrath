-- RollForSync — Passive listener for RollFor's AceComm broadcast channel.
-- Decodes RF_* messages and dispatches them to registered LootBlare callbacks.
-- Gracefully degrades if required libraries are missing (addon still works without RollFor).

local _, addon = ...

local CHANNEL = "RollForSync"

-- ============================================================
-- CALLBACK REGISTRY
-- ============================================================
addon.rfCallbacks = addon.rfCallbacks or {}
addon.rfSyncActive = false

function addon.RegisterRFCallback(messageType, callback)
    if not addon.rfCallbacks[messageType] then
        addon.rfCallbacks[messageType] = {}
    end
    table.insert(addon.rfCallbacks[messageType], callback)
end

function addon.FireRFCallbacks(messageType, payload)
    local cbs = addon.rfCallbacks[messageType]
    if not cbs then return end
    for i = 1, #cbs do
        cbs[i](payload)
    end
end

-- ============================================================
-- LIBRARY ACQUISITION (graceful degradation)
-- ============================================================
local lib_stub = LibStub
if not lib_stub then
    return
end

local ace_comm    = lib_stub("AceComm-3.0", true)
local lib_serialize = lib_stub("LibSerialize", true)
local lib_deflate   = lib_stub("LibDeflate", true)

if not ace_comm or not lib_serialize or not lib_deflate then
    local frame = DEFAULT_CHAT_FRAME
    if frame then
        frame:AddMessage("|cffff8800LootBlare:|r RollFor sync disabled — missing AceComm/LibSerialize/LibDeflate.")
    end
    return
end

-- ============================================================
-- DECODE PIPELINE (mirrors RollForReceiver.lua exactly)
-- ============================================================
local function decode(encoded)
    local ok, result = pcall(function()
        local compressed = lib_deflate:DecodeForWoWAddonChannel(encoded)
        if not compressed then return nil end
        local decompressed = lib_deflate:DecompressDeflate(compressed)
        if not decompressed then return nil end
        local ok2, payload = lib_serialize:Deserialize(decompressed)
        if ok2 then return payload end
    end)
    if ok then return result end
end

-- ============================================================
-- ACECOMM REGISTRATION
-- ============================================================
ace_comm:RegisterComm(CHANNEL, function(_, encoded, _, sender)
    -- LootBlare listens to ALL broadcasts including our own.
    -- (Unlike RollForReceiver, we want RF_START from our own ML client
    -- so auto-roll and preview tracking work when we're the ML.)

    local payload = decode(encoded)
    if not payload or not payload.type then return end
    addon.FireRFCallbacks(payload.type, payload)
end)

addon.rfSyncActive = true
