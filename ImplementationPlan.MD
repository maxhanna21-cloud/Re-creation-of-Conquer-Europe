Context
When a player clicks "Buy Attacker" or "Buy Defender" but has fewer than 10,000 manpower, the server silently rejects the purchase (the error() inside pcall only logs a server-side warn). The player gets no feedback. We need to show the existing ReminderPopup with a clear "not enough manpower" message.
Approach
Reuse the existing DiplomacyReminderEvent remote and the queue-based ReminderPopup in DiplomacyGui.client.luau. Two files modified, zero new files or RemoteEvents.
Changes
1. src/server/NPCPurchaseHandler.server.luau
a) Add DiplomacyReminderEvent reference (after line 9):
lualocal DiplomacyReminderEvent = ReplicatedStorage:WaitForChild("DiplomacyReminderEvent", 10)
b) Handle insufficient manpower as a normal validation failure (lines 56-58):
Replace error() with a FireClient + return so the pcall succeeds cleanly and the lock is released without logging a warning.
Change:
luaif not manpower or math.floor(manpower.Value) < cost then
    error("Insufficient manpower (need " .. cost .. ")")
end
To:
luaif not manpower or math.floor(manpower.Value) < cost then
    if DiplomacyReminderEvent then
        DiplomacyReminderEvent:FireClient(player, nil, "InsufficientManpower", cost)
    end
    return
end
Argument order: player, nil, "InsufficientManpower", cost maps to client params (aggressorCountry=nil, eventType="InsufficientManpower", extraData=cost). The nil keeps aggressorCountry unused; eventType routes correctly; cost arrives in extraData.
The return exits the anonymous pcall function. success will be true, no warn is logged, and the lock is still released on line 84.
2. src/client/DiplomacyGui.client.luau
a) Add optional third parameter to the event handler (line 247):
Change:
luaDiplomacyReminderEvent.OnClientEvent:Connect(function(aggressorCountry, eventType)
To:
luaDiplomacyReminderEvent.OnClientEvent:Connect(function(aggressorCountry, eventType, extraData)
Existing event types don't pass a third argument, so extraData will be nil for them — no behavior change.
b) Add new elseif branch (between lines 267 and 268, after NAPExpired, before else):
luaelseif eventType == "InsufficientManpower" then
    local requiredCost = tonumber(extraData) or 10000
    message = "Not enough manpower! You need " .. requiredCost .. " manpower to purchase a unit."
    color = Color3.fromRGB(255, 170, 50)
aggressorCountry is nil for this event type (unused). The cost comes through extraData with a tonumber fallback to 10000 for safety. Existing diplomacy branches are unaffected since they never pass a third argument (extraData is nil for them).
Critical files

/home/user/Re-creation-of-Conquer-Europe/src/server/NPCPurchaseHandler.server.luau — server purchase handler
/home/user/Re-creation-of-Conquer-Europe/src/client/DiplomacyGui.client.luau — client reminder popup

Verification

Join the game with a country that has < 10,000 manpower
Click either Buy Attacker or Buy Defender
Confirm the ReminderPopup appears with orange text: "Not enough manpower! You need 10000 manpower to purchase a unit."
Click OK to dismiss
Earn enough manpower (wait for income ticks) and confirm purchasing works normally
Spam-click the buy button — confirm rate limiting prevents reminder flood