local Utils = require(".Utils")
local FRLG = require(".FireRed_LeafGreen")
local mod = {}

-- CONSTANTS
--- Maximum number of remote players that can be drawn at once.
--- This does NOT affect how many people can be in your game at once or even nearby.
--- If there are more players nearby than you can draw, they just won't be drawn.
--- Increase this at your own risk. A number too big could corrupt memory or something.
--- - "4" seems pretty safe.
--- - "8" has worked in a few, non-rigorous tests.
--- - "32" shows up in a comment indicating a theoretical maximum value.
local MAX_RENDERED_PLAYERS = 8

--- Version number for this client script. Used to track compatibility with the server.
local VERSION_NUMBER = 1018

--- Flip the gender of remote players. Used for debugging sprites.
local DEBUG_GENDER_SWITCH = false

local PACKET_PLAYER_UPDATE      = "SPOS"
--- Sent by the server to tell a client it should stop tracking another.
--- This happens when they disconnect or when somebody moves to a different area that the server
--- doesn't think they can be seen from.
local PACKET_PLAYER_EXIT        = "EXIT"
--- Sent by the client to request the Pokemon of another.
--- A client receiving this will respond with a series of 6 `POKE` packets.
local PACKET_REQUEST_POKEMON    = "RPOK"
--- Sent by the client in response to an `RPOK`.
--- Contains the player's party of Pokemon.
local PACKET_RAW_POKEMON_DATA   = "POKE"
--- Sent by the client who is too busy to respond to another player's request.
--- This can happen in response to Trade requests and Battle requests
local PACKET_TOO_BUSY           = "TBUS"
--- Sent by the client to request to trade with another.
local PACKET_REQUEST_TRADE      = "RTRA"
--- Sent by the client to accept the trade.
local PACKET_DECLINE_TRADE      = "DTRA"
--- Sent by the client to decline the trade.
local PACKET_ACCEPT_TRADE       = "STRA"
--- Sent by the client, containing raw trade payloads.
local PACKET_RAW_TRADE_DATA     = "TRAD"
--- Sent by the client to cancel a previously accepted trade.
local PACKET_CANCEL_TRADE       = "CTRA"
--- Sent by the client if they refuse a trade offer.
local PACKET_REFUSE_TRADE_OFFER = "ROFF"
--- Sent by the client, challenging another to battle.
local PACKET_REQUEST_BATTLE     = "RBAT"
--- Sent by the client, declining the challenge.
local PACKET_DECLINE_BATTLE     = "DBAT"
--- Sent by the client, accepting the challenge.
local PACKET_ACCEPT_BATTLE      = "SBAT"
--- Sent by the client, containing raw battle data.
local PACKET_RAW_BATTLE_DATA    = "BATT"
--- Sent by the client, canceling a previously accepted battle.
local PACKET_CANCEL_BATTLE      = "CBAT"
--- Sent by clients to one another.
--- I believe this is for forwarding raw Link Cable communications.
local PACKET_RAW_LINK_DATA      = "SLNK"

-- SESSION VARIABLES
--- The currently loaded rom.
local RomCard
--- Whether or not to render players on this screen
local ShouldDrawRemotePlayers = 0
--- Collection of render addresses to use for remote players.
--- Initialized on game start.
local Renderers = {}
--- The address used for multiple choice prompts
--- Needs to be set during initialization
local MultichoiceAdr = 0
--- The offset to apply to the "Bike" value
--- Needs to be set during initialization
local BikeOffset = 0

-- MULTIPLAYER VARS
--- The Nickname of the player we're talking to
local TargetPlayer = "00000000"
--- All of the remote players that MIGHT be visible to us.
local PlayerProxies = {}

-- LOCAL PLAYER VARS
local CameraX = 0
local CameraY = 0
-- ???
local LocalPlayerMapXMovePrev = 0
local LocalPlayerMapYMovePrev = 0
--- The ID of the current map
local LocalPlayerMapID = 0
--- The ID of the previous map
local LocalPlayerMapIDPrev = 0
--- How the current map was entered from the previous map
local LocalPlayerMapEntranceType = 1
--- Whether the player has changed maps this frame
local LocalPlayerMapChange = 0
--- The direction the local player is facing.
--- Initialize to up, because it conveys to other players that you might not
--- quite be ready yet.
--- - 1 = LEFT
--- - 2 = RIGHT
--- - 3 = UP
--- - 4 = DOWN
local LocalPlayerCurrentDirection = 3
-- ??? This may represent the offset of the current map to the previous.
local LocalPlayerDifferentMapX = 0
local LocalPlayerDifferentMapY = 0
-- The current position
local LocalPlayerCurrentX = 0
local LocalPlayerCurrentY = 0
-- The previous position
local LocalPlayerPreviousX = 0
local LocalPlayerPreviousY = 0
-- This is the coordinate that the player entered this map on
local LocalPlayerStartX = 0
local LocalPlayerStartY = 0
-- TODO: figure out what this does and rename it
--- Something to do with sprites and animation.
--- This value correlates to a default standing pose.
local LocalPlayerExtra1 = 2
--- Sprite Number (0 = Male, 1 = Female)
local LocalPlayerGender = 0
--- Player Movement Method (0 = Walking, 1 = Biking, 2 = Surfing)
--- Used for some initial decoding and sent to other players, but doesn't seem to be used by other players.
local LocalPlayerMovementMethod = 0
--- Whether the player is in a battle (0 = No, 1 = Yes)
local LocalPlayerIsInBattle = 0


local Keypressholding = 0
local LockFromScript = 0
-- Wonder if there's an easy way to restore Hide and Seek mode.
local HideSeek = 0
local HideSeekTimer = 0
local PrevExtraAdr = 0
local Var8000 = {}
local Var8000Adr = {
    [1]  = 33779896,
    [2]  = 33779896 + 2,
    [3]  = 33779896 + 4,
    [4]  = 33779896 + 6,
    [5]  = 33779896 + 8,
    [6]  = 33779896 + 10,
    [14] = 33779896 + 26
}
local TextSpeedWait = 0
local OtherPlayerHasCancelled = 0
local TradeVars = { 0, 0, 0, 0, "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" }
local EnemyTradeVars = { 0, 0, 0, 0, 0 }
local BattleVars = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local EnemyBattleVars = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local Pokemon = { "", "", "", "", "", "" }
local EnemyPokemon = { "", "", "", "", "", "" }


-- NETWORKING ----------------------------------------------------------------------------------------------------------
--- Helper method to slip the target player id into the packet as the destination.
local function _SendToPlayer(PacketType, Payload)
    SendData(PacketType, TargetPlayer, Payload)
end

--- Helper method to ask another player for their pokemon data.
--- Also clears out the variables used to store them.
local function _RequestRawPokemonData()
    for i = 1, 6 do
        EnemyPokemon[i] = ""
    end
    _SendToPlayer(PACKET_REQUEST_POKEMON)
end

--- Load pokemon data from memory and store them in our variables.
local function _GetPokemonTeam()
    local ReadTemp = ""
    local PokemonTeamADRTEMP = 33702532
    for j = 1, 6 do
        for i = 1, 25 do
            ReadTemp = emu:read32(PokemonTeamADRTEMP)
            PokemonTeamADRTEMP = PokemonTeamADRTEMP + 4
            ReadTemp = tonumber(ReadTemp)
            ReadTemp = ReadTemp + 1000000000
            if i == 1 then
                Pokemon[j] = ReadTemp
            else
                Pokemon[j] = Pokemon[j] .. ReadTemp
            end
        end
    end
end

--- Helper method to send pokemon data to the other player.
local function _SendRawPokemonData()
    _GetPokemonTeam()
    local PokeTemp
    local StartNum = 0
    local StartNum2 = 0
    for j = 1, 6 do
        for i = 1, 10 do
            StartNum = ((i - 1) * 25) + 1
            StartNum2 = StartNum + 24
            PokeTemp = string.sub(Pokemon[j], StartNum, StartNum2)
            _SendToPlayer(PACKET_RAW_POKEMON_DATA, PokeTemp)
        end
    end
end

--- Helper method to send raw trade data to the other player.
local function _SendRawTradeData()
    _SendToPlayer(PACKET_RAW_TRADE_DATA, TradeVars[1] .. TradeVars[2] .. TradeVars[3] .. TradeVars[5])
end

--- Helper method to send raw battle data to the other player.
local function _SendRawBattleData()
    _SendToPlayer(PACKET_RAW_BATTLE_DATA, BattleVars[1] .. BattleVars[2] .. BattleVars[3] .. BattleVars[4] .. BattleVars[5] .. BattleVars[6] .. BattleVars[7] .. BattleVars[8] .. BattleVars[9] .. BattleVars[10])
end


-- Unused Networking functions -----------------------------------------------------------------------------------------
-- I don't know what the best way to handle this would be.
-- I could remove it and refer to previous commits for reference,
-- but it may become even further desynced by refactorings.
--
-- For now, I'll leave it in and update values when I refactor.

local function _SendRawLinkData(size)
    size = size or 0
    local SizeAct = size + 1000000000
    --		SizeAct = tostring(SizeAct)
    --		SizeAct = string.format("%.0f",SizeAct)
    _SendToPlayer(PACKET_RAW_LINK_DATA, SizeAct)
end

local function _SendMultiplayerPackets(Offset, size)
    local Packet = ""
    local ModifiedSize = 0
    local ModifiedLoop = 0
    local ModifiedLoop2 = 0
    local PacketAmount = 0
    --Using RAM 0263DE00 for packets, as it seems free. If not, will modify later
    if Offset == 0 then
        Offset = 40099328
    end
    local ModifiedRead = ""
    if size > 0 then
        _SendRawLinkData(size)
        for i = 1, size do
            --Inverse of i, size remaining. 1 = last. Also size represents hex bytes, which goes up to 255 in decimal, so we triple it.
            ModifiedSize = size - i + 1
            if ModifiedSize > 20 and ModifiedLoop == 0 then
                PacketAmount = PacketAmount + 1
                ModifiedLoop = 20
                ModifiedLoop2 = 0
                --	console:log("Packet number: " .. PacketAmount)
            elseif ModifiedSize <= 20 and ModifiedLoop == 0 then
                PacketAmount = PacketAmount + 1
                ModifiedLoop = ModifiedSize
                ModifiedLoop2 = 0
                --	console:log("Last packet. Number: " .. PacketAmount)
            end
            if ModifiedLoop ~= 0 then
                ModifiedLoop2 = ModifiedLoop2 + 1
                ModifiedRead = emu:read8(Offset)
                ModifiedRead = tonumber(ModifiedRead)
                ModifiedRead = ModifiedRead + 100
                if Packet == "" then
                    Packet = ModifiedRead
                else
                    Packet = Packet .. ModifiedRead
                end
                if ModifiedLoop == 1 then
                    --SocketMain:send(Packet)
                    --			console:log("Packet sent! Packet " .. Packet .. " end. Amount of loops: " .. ModifiedLoop2 .. " " .. Offset)
                    Packet = ""
                    ModifiedLoop = 0
                else
                    ModifiedLoop = ModifiedLoop - 1
                end
            end
            Offset = Offset + 1
        end
    end
end

local function _ReceiveMultiplayerPackets(size)
    local Packet = ""
    local ModifiedSize = 0
    local ModifiedLoop = 0
    local ModifiedLoop2 = 0
    local PacketAmount = 0
    local ModifiedRead
    local ModifiedLoop3 = 0
    local SizeMod = 0
    --Using RAM 0263D000-0263DDFF for received data, as it seems free. If not, will modify later
    local MultiplayerPacketSpace = 40095744
    --console:log("TEST 1")
    for i = 1, size do
        --Inverse of i, size remaining. 1 = last. Also size represents hex bytes, which goes up to 255 in decimal
        ModifiedSize = size - i + 1
        if ModifiedSize > 20 and ModifiedLoop == 0 then
            PacketAmount = PacketAmount + 1
            --Packet = SocketMain:receive(60)
            ModifiedLoop = 20
            ModifiedLoop2 = 0
            --		console:log("Packet number: " .. PacketAmount)
        elseif ModifiedSize <= 20 and ModifiedLoop == 0 then
            PacketAmount = PacketAmount + 1
            SizeMod = ModifiedSize * 3
            --Packet = SocketMain:receive(SizeMod)
            ModifiedLoop = ModifiedSize
            ModifiedLoop2 = 0
            --		console:log("Last packet. Number: " .. PacketAmount)
        end
        if ModifiedLoop ~= 0 then
            ModifiedLoop3 = ModifiedLoop2 * 3 + 1
            ModifiedLoop2 = ModifiedLoop2 + 1
            SizeMod = ModifiedLoop3 + 2
            ModifiedRead = string.sub(Packet, ModifiedLoop3, SizeMod)
            ModifiedRead = tonumber(ModifiedRead)
            ModifiedRead = ModifiedRead - 100
            emu:write8(MultiplayerPacketSpace, ModifiedRead)
            --		console:log("Num: " .. ModifiedRead)
            --		console:log("NUM: " .. ModifiedRead)
            if ModifiedLoop == 1 then
                --		console:log("Packet " .. PacketAmount .. " end. Amount of loops: " .. ModifiedLoop2 .. " " .. MultiplayerPacketSpace)
                Packet = ""
                ModifiedLoop = 0
            else
                ModifiedLoop = ModifiedLoop - 1
            end
        end
        MultiplayerPacketSpace = MultiplayerPacketSpace + 1
    end
end


-- REUSABLE ROM INTERACTIONS -------------------------------------------------------------------------------------------
-- I feel this stuff would do well in a separate file.
-- TODO: Could these integer array funcs be one method with the target passed in?

--- Given an array of 32-bit integers and a start address, write each integer to the subsequent address.
--- Assumes the input is an integer-indexed table, starting with 1, and contains no nil values.
local function WriteIntegerArrayToRom(startAddress, array)
    local i = 0
    local val = 0
    while true do
        val = array[i + 1] -- because lua arrays start at 1
        if val == nil then
            break
        end
        RomCard:write32(startAddress + i * 4, val)
        i = i + 1
    end
end

--- Given an array of 32-bit integers and a start address, write each integer to the subsequent address.
--- Assumes the input is an integer-indexed table, starting with 1, and contains no nil values.
local function WriteIntegerArrayToEmu(startAddress, array)
    local i = 0
    local val = 0
    while true do
        val = array[i + 1] -- because lua arrays start at 1
        if val == nil then
            break
        end
        emu:write32(startAddress + i * 4, val)
        i = i + 1
    end
end

--- Given a string and a numeric hex address,
--- this converts each character to ascii, applies an offset,
--- then writes each byte to memory starting at that address.
--- The string is terminated with a special FF character.
---
--- It is used for displaying player nicknames when interacting.
local function _WriteTextToAddress(text, startAddress)
    local cleantext = Utils.Trim(text)
    local num
    for i = 1, string.len(cleantext) do
        num = string.sub(cleantext, i, i)
        num = string.byte(num)
        num = tonumber(num)
        if num > 64 and num < 93 then
            num = num + 122
        elseif num > 92 and num < 128 then
            num = num + 116
        else
            num = num + 113
        end
        emu:write8(startAddress + i - 1, num)
    end
    emu:write8(startAddress + string.len(cleantext), 255)
end


-- LOGIC AND SCRIPTS ---------------------------------------------------------------------------------------------------
--- Returns true if this byte is not 0.
--- I do not know under what circumstances this byte is set.
local function _IsBusy()
    return emu:read8(50335644) ~= 0
end

--- Something related to multichoice prompts.
local function FixAddress()
    if PrevExtraAdr ~= 0 then
        emu:write32(MultichoiceAdr, PrevExtraAdr)
    end
end

--- After a script is loaded into memory, this function is used to execute it.
local function _ExecuteLoadedScript()
    local ScriptAddress = 50335400
    local ScriptAddress2 = 145227776

    --Either use 66048, 512, or 513.
    --134654353 and 145293312 freezes the game
    local touchyAddress = 513

    WriteIntegerArrayToEmu(ScriptAddress, { 0, 0, touchyAddress, 0, ScriptAddress2 + 1, 0, 0, 0, 0, 0, 0, 0})
end

--- Write data to a buffer?
local function _WriteBuffers(BufferOffset, BufferVar, Length)
    local BufferOffset2 = BufferOffset
    local BufferVarSeperate
    local String1 = 0
    local String2 = 0
    for i = 1, Length do
        if i == 1 then
            String1 = 1
        else
            String1 = String1 + 10
        end
        String2 = String1 + 9
        BufferVarSeperate = string.sub(BufferVar, String1, String2)
        BufferVarSeperate = tonumber(BufferVarSeperate)
        BufferVarSeperate = BufferVarSeperate - 1000000000
        emu:write32(BufferOffset2, BufferVarSeperate)
        BufferOffset2 = BufferOffset2 + 4
    end
end

--- Load the given script into memory.
--- This also does any setup related to the given script.
local function _Loadscript(ScriptNo)
    --2 is where the script itself is, whereas 1 is the memory to force it to read that. 3 is an extra address to use alongside it, such as multi-choice
    local ScriptAddress2 = 145227776

    local ScriptAddress3 = 145227712

    local MultichoiceAdr2 = ScriptAddress3 - 32
    local Buffer1 = 33692880
    local Buffer2 = 33692912
    local Buffer3 = 33692932

    if ScriptNo == 0 then
        RomCard:write32(ScriptAddress2, 4294902380)
        --		LoadScriptIntoMemory()
        --Host script
    elseif ScriptNo == 1 then
        emu:write16(Var8000Adr[2], 0)
        emu:write16(Var8000Adr[5], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 603983722, 151562240, 2148344069, 17170433, 145227804, 25166870, 4278348800, 41944086, 4278348800, 3773424593, 3823960280, 3722445033, 3892369887, 3805872355, 3655390933, 3638412030, 3034710233, 3654929664, 16755935})
        _ExecuteLoadedScript()
        --Interaction Menu	Multi Choice
    elseif ScriptNo == 2 then
        emu:write16(Var8000Adr[1], 0)
        emu:write16(Var8000Adr[2], 0)
        emu:write16(Var8000Adr[14], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 1664873, 1868957864, 132117, 226492441, 2147489664, 40566785, 3588018687, 3823829224, 14213353, 15328237, 3655327200, 14936318, 3942704088, 14477533, 4289463293, 4294967040})

        _WriteTextToAddress(TargetPlayer, Buffer2)

        --First save multichoice in case it's needed later
        PrevExtraAdr = RomCard:read32(MultichoiceAdr)
        --Overwrite multichoice 0x2 with a custom at address MultichoiceAdr2
        RomCard:write32(MultichoiceAdr, MultichoiceAdr2)
        --Multi-Choice
        WriteIntegerArrayToRom(MultichoiceAdr2, {
            ScriptAddress3, 0, ScriptAddress3 + 7, 0, ScriptAddress3 + 13, 0, ScriptAddress3 + 18, 0
        })
        --Text
        WriteIntegerArrayToRom(ScriptAddress3, { 3907573180, 3472873952, 3654866406, 3872767487, 3972005848, 4294961373})
        _ExecuteLoadedScript()
        --Placeholder
    elseif ScriptNo == 3 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632321, 3907242239, 3689078236, 3839220736, 3655522788, 16756952, 4294967295})
        _ExecuteLoadedScript()
        --Waiting message
    elseif ScriptNo == 4 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 1271658, 375785640, 5210113, 654415909, 3523150444, 3723025877, 3657489378, 3808487139, 3873037544, 3588285440, 2967919085, 4294902015})
        _ExecuteLoadedScript()
        --Cancel message
    elseif ScriptNo == 5 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632325, 3655126783, 3706249984, 3825264345, 3656242656, 3587965158, 3587637479, 3772372962, 4289583321, 4294967040})
        _ExecuteLoadedScript()
        --Trade request
    elseif ScriptNo == 6 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 469765994, 151562240, 2148344069, 393217, 145227850, 41943318, 4278348800, 3942646781, 3655133149, 3823632615, 3588679680, 3942701528, 14477533, 2917786605, 14925566, 15328237, 3654801365, 4289521892, 18284288, 1811939712, 4294967042})
        _ExecuteLoadedScript()

        _WriteTextToAddress(TargetPlayer, Buffer2)

        --Trade request denied
    elseif ScriptNo == 7 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632321, 3655126783, 3706249984, 3825264345, 3656242656, 3822584038, 3808356313, 3942705379, 14477277, 3892372456, 3654866406, 4278255533})
        _ExecuteLoadedScript()
        --Trade offer
    elseif ScriptNo == 8 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 469765994, 151562240, 2148344069, 393217, 145227866, 41943318, 4278348800, 15328211, 3656046044, 3671778048, 3638159065, 2902719744, 3655126782, 3587965165, 3808483818, 3873037018, 4244691161, 3522931970, 14737629, 15328237, 3654801365, 4289521892, 18284288, 1811939712, 4294967042})
        _ExecuteLoadedScript()
        --Trade offer denied
    elseif ScriptNo == 9 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632321, 3655126783, 3588679680, 3691043288, 3590383573, 14866905, 3772242392, 3638158045, 4278255533})
        _ExecuteLoadedScript()
        --Battle request
    elseif ScriptNo == 10 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 469765994, 151562240, 2148344069, 393217, 145227846, 41943318, 4278348800, 3942646781, 3655133149, 3823632615, 3906328064, 14278888, 2917786605, 14925566, 15328237, 3654801365, 4289521892, 18284288, 1811939712, 4294967042})
        _ExecuteLoadedScript()

        _WriteTextToAddress(TargetPlayer, Buffer2)

        --Battle request denied
    elseif ScriptNo == 11 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632321, 3655126783, 3706249984, 3825264345, 3656242656, 3822584038, 3808356313, 3942705379, 14477277, 3590382568, 3773360341, 16756185, 4294967295})
        _ExecuteLoadedScript()
        --Select Pokemon for trade
    elseif ScriptNo == 12 then
        emu:write16(Var8000Adr[1], 0)
        emu:write16(Var8000Adr[2], 0)
        emu:write16(Var8000Adr[4], 0)
        emu:write16(Var8000Adr[5], 0)
        emu:write16(Var8000Adr[14], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 10429802, 2147754279, 67502086, 145227809, 1199571750, 50429185, 2147554944, 40632322, 2147555071, 40632321, 4294967295})
        _ExecuteLoadedScript()
        --Battle will start
    elseif ScriptNo == 13 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 1416042, 627443880, 1009254542, 2147554816, 40632322, 3924022271, 3587571942, 3655395560, 3772640000, 3823239392, 3654680811, 2917326299, 4294902015})
        _ExecuteLoadedScript()
        --Trade will start
    elseif ScriptNo == 14 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 1416042, 627443880, 1009254542, 2147554816, 40632322, 3924022271, 3873964262, 14276821, 3772833259, 3957580288, 3688486400, 4289585885, 4294967040})
        _ExecuteLoadedScript()
        --You have canceled the battle
    elseif ScriptNo == 15 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632326, 3924022271, 3939884032, 3587637465, 3772372962, 14211552, 14277864, 3907573206, 4289583584, 4294967040})
        _ExecuteLoadedScript()
        --You have canceled the trade
    elseif ScriptNo == 16 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632326, 3924022271, 3939884032, 3587637465, 3772372962, 14211552, 14277864, 3637896936, 16756185, 4294967295})
        _ExecuteLoadedScript()
        --Trading. Your pokemon is stored in 8004, whereas enemy pokemon is already stored through setenemypokemon command
    elseif ScriptNo == 17 then
        emu:write16(Var8000Adr[2], 0)
        emu:write16(Var8000Adr[6], Var8000[5])
        WriteIntegerArrayToRom(ScriptAddress2, { 16655722, 2147554855, 40632321, 4294967295})
        _ExecuteLoadedScript()
        --Cancel Battle
    elseif ScriptNo == 18 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632325, 3655126783, 3706249984, 3825264345, 3656242656, 3587965158, 3587637479, 3772372962, 4275624416, 14277864, 3907573206, 4289583584, 4294967040})
        _ExecuteLoadedScript()
        --Cancel Trading
    elseif ScriptNo == 19 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632325, 3655126783, 3706249984, 3825264345, 3656242656, 3587965158, 3587637479, 3772372962, 4275624416, 14277864, 3637896936, 16756185, 4294967295})
        _ExecuteLoadedScript()
        --other player is too busy to battle.
    elseif ScriptNo == 20 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632321, 3722235647, 3873964263, 3655523797, 3655794918, 15196633, 4276347880, 3991398870, 14936064, 3907573206, 4289780192, 4294967040})
        _ExecuteLoadedScript()
        --other player is too busy to trade.
    elseif ScriptNo == 21 then
        emu:write16(Var8000Adr[2], 0)
        WriteIntegerArrayToRom(ScriptAddress2, { 285216618, 151562240, 2147554822, 40632321, 3722235647, 3873964263, 3655523797, 3655794918, 15196633, 4276347880, 3991398870, 14936064, 3637896936, 16756953, 4294967295})
        _ExecuteLoadedScript()
        --battle script
    elseif ScriptNo == 22 then
        emu:write16(Var8000Adr[2], 0)
        RomCard:write32(ScriptAddress2, 40656234)
        _ExecuteLoadedScript()
        --trade names script.
    elseif ScriptNo == 23 then
        --Other trainer aka other player

        _WriteTextToAddress(TargetPlayer, Buffer1)

        --Their pokemon
        _WriteBuffers(Buffer3, EnemyTradeVars[6], 5)
    end

end

--- Only used by a commented block in OnKeysRead
local function _ApplyMovement(MovementType)
    local ScriptAddress = 50335400
    local ScriptAddress2 = 145227776
    local ScriptAddressTemp = 0
    ScriptAddressTemp = ScriptAddress2
    RomCard:write32(ScriptAddressTemp, 16732010)
    ScriptAddressTemp = ScriptAddressTemp + 4
    RomCard:write32(ScriptAddressTemp, 145227790)
    ScriptAddressTemp = ScriptAddressTemp + 4
    RomCard:write32(ScriptAddressTemp, 1811939409)
    ScriptAddressTemp = ScriptAddressTemp + 4
    RomCard:write16(ScriptAddressTemp, 65282)
    if MovementType == 0 then
        ScriptAddressTemp = ScriptAddressTemp + 2
        RomCard:write16(ScriptAddressTemp, 65024)
        _ExecuteLoadedScript()
    elseif MovementType == 1 then
        ScriptAddressTemp = ScriptAddressTemp + 2
        RomCard:write16(ScriptAddressTemp, 65025)
        _ExecuteLoadedScript()
    elseif MovementType == 2 then
        ScriptAddressTemp = ScriptAddressTemp + 2
        RomCard:write16(ScriptAddressTemp, 65026)
        _ExecuteLoadedScript()
    elseif MovementType == 3 then
        ScriptAddressTemp = ScriptAddressTemp + 2
        RomCard:write16(ScriptAddressTemp, 65027)
        _ExecuteLoadedScript()
    end
end

--- TODO: not implemented
local function _Battlescript()
end

--- Only used in _BattlescriptClassic
local function _WriteRom(RomOffset, RomVar, Length)
    local RomOffset2 = RomOffset
    local RomVarSeperate
    local String1 = 0
    local String2 = 0
    for i = 1, Length do
        if i == 1 then
            String1 = 1
        else
            String1 = String1 + 10
        end
        String2 = String1 + 9
        RomVarSeperate = string.sub(RomVar, String1, String2)
        RomVarSeperate = tonumber(RomVarSeperate)
        RomVarSeperate = RomVarSeperate - 1000000000
        RomCard:write32(RomOffset2, RomVarSeperate)
        RomOffset2 = RomOffset2 + 4
    end
end

--- Read data from buffers?
local function ReadBuffers(BufferOffset, Length)
    local BufferOffset2 = BufferOffset
    local BufferVar
    local BufferVarSeperate
    for i = 1, Length do
        BufferVarSeperate = emu:read32(BufferOffset2)
        BufferVarSeperate = tonumber(BufferVarSeperate)
        BufferVarSeperate = BufferVarSeperate + 1000000000
        if i == 1 then
            BufferVar = BufferVarSeperate
        else
            BufferVar = BufferVar .. BufferVarSeperate
        end
        BufferOffset2 = BufferOffset2 + 4
    end
    return BufferVar
end

--- Loads the other player's pokemon data into our variables.
--- Only used by _BattlescriptClassic
local function _SetEnemyPokemonTeam(EnemyPokemonNo, EnemyPokemonPos)
    local String1 = 0
    local String2 = 0
    local ReadTemp = ""
    local PokemonTeamADRTEMP = 33701932
    if EnemyPokemonNo == 0 then
        for j = 1, 6 do
            for i = 1, 25 do
                if i == 1 then
                    String1 = i
                else
                    String1 = String1 + 10
                end
                String2 = String1 + 9
                ReadTemp = string.sub(EnemyPokemon[j], String1, String2)
                ReadTemp = tonumber(ReadTemp)
                ReadTemp = ReadTemp - 1000000000
                emu:write32(PokemonTeamADRTEMP, ReadTemp)
                PokemonTeamADRTEMP = PokemonTeamADRTEMP + 4
            end
        end
    else
        PokemonTeamADRTEMP = PokemonTeamADRTEMP + ((EnemyPokemonPos - 1) * 100)
        for i = 1, 25 do
            if i == 1 then
                String1 = i
            else
                String1 = String1 + 10
            end
            String2 = String1 + 9
            ReadTemp = string.sub(EnemyPokemon[EnemyPokemonNo], String1, String2)
            ReadTemp = tonumber(ReadTemp)
            ReadTemp = ReadTemp - 1000000000
            emu:write32(PokemonTeamADRTEMP, ReadTemp)
            PokemonTeamADRTEMP = PokemonTeamADRTEMP + 4
        end
    end
end

--- Old version of battle script.
--- I don't know why this was scrapped.
local function _BattlescriptClassic()
    --Cursor

    BattleVars[2] = emu:read8(33701880)
    --Battle finished. 1 = yes, 0 = is still ongoing
    BattleVars[3] = emu:read8(33701514)
    --Phase. 4 = finished moves.
    BattleVars[4] = emu:read8(33701506)
    --Speed. 256 = You move first. 1 = You move last
    BattleVars[5] = emu:read16(33700830)
    if BattleVars[5] > 10 then
        BattleVars[5] = 1
    else
        BattleVars[5] = 0
    end

    --Initialize battle
    if BattleVars[1] == 0 then
        BattleVars[1] = 1
        BattleVars[11] = 1

        _Loadscript(22)
        --Trainerbattleoutro
        local Buffer1 = 33785528
        local Buffer2 = 145227780
        --Outro for battle. "Thanks for the great battle."
        local Bufferloc = "1145227780"
        local Bufferstring = "48056665104657492447489237321946742660764906329062490632806439167372565294967295"

        --514 = Player red ID, 515 = Leaf aka female
        emu:write16(33785518, 514)
        --Cursor. Set to 0
        emu:write8(33701880, 0)
        --Set win to 0
        emu:write8(33701514, 0)
        --Set speeds to 0
        emu:write16(33700830, 0)
        --Set turn to 0
        emu:write8(33700834, 0)

        _WriteBuffers(Buffer1, Bufferloc, 1)
        _WriteRom(Buffer2, Bufferstring, 8)

        --Wait 150 frames for other vars to load
    elseif BattleVars[1] == 1 and BattleVars[11] < 150 then
        BattleVars[11] = BattleVars[11] + 1
        --514 = Player red ID, 515 = Leaf aka female
        emu:write16(33785518, 514)
        --Cursor. Set to 0
        emu:write8(33701880, 0)
        --Set win to 0
        emu:write8(33701514, 0)
        --Set speeds to 0
        emu:write16(33700830, 0)
        --Set turn to 0
        emu:write8(33700834, 0)
        if BattleVars[11] >= 150 then
            --Set enemy team
            _SetEnemyPokemonTeam(0, 1)
            BattleVars[1] = 2
        end

        --Battle loop
    elseif BattleVars[1] == 2 then
        BattleVars[12] = emu:read8(33700808)

        --If both players have not gone
        if BattleVars[6] == 0 then
            --You have not decided on a move
            if BattleVars[4] >= 2 and EnemyBattleVars[4] ~= 4 then
                --Pause until other player has made a move
                if BattleVars[12] < 32 then
                    BattleVars[12] = BattleVars[12] + 32
                    emu:write8(33700808, BattleVars[12])
                end
            elseif BattleVars[4] >= 4 and EnemyBattleVars[4] >= 4 then
                if BattleVars[12] >= 32 then
                    BattleVars[12] = BattleVars[12] - 32
                    emu:write8(33700808, BattleVars[12])
                end
                --if MasterClient == "h" then
                --    if BattleVars[5] == 1 then
                --        BattleVars[6] = 1
                --    else
                --        BattleVars[6] = 2
                --    end
                --else
                    if EnemyBattleVars[5] == 1 then
                        BattleVars[6] = 2
                    else
                        BattleVars[6] = 1
                    end
                --end
            end
            --You go first
        elseif BattleVars[6] == 1 then
            local TurnTime = emu:read8(33700834)
            --Write speed to 256
            emu:write16(33700830, 256)
            if BattleVars[7] == 0 then
                BattleVars[7] = 1
                --	BattleVars[13] = ReadBuffers()
                console:log("First")
            elseif BattleVars[7] == 1 then
            end
            --You go second
            local TurnTime = emu:read8(33700834)
        elseif BattleVars[6] == 2 then
            --Write speed to 1
            emu:write16(33700830, 1)
            if BattleVars[7] == 0 then
                BattleVars[7] = 1
                --	BattleVars[13] = ReadBuffers()
                console:log("Second")
            elseif BattleVars[7] == 1 then
            end
        end
    end

    --Prevent item use
    if BattleVars[1] >= 2 and BattleVars[2] == 1 then
        emu:write8(33696589, 1)
    else
        emu:write8(33696589, 0)
    end

    --Unlock once battle ends
    if BattleVars[1] >= 2 and BattleVars[3] == 1 then
        LockFromScript = 0
    end

    _SendRawBattleData()
end

--- Loads the other player's pokemon data into our own variables
local function _SetPokemonData(PokeData)
    for i = 1, 6 do
        if string.len(EnemyPokemon[i]) < 250 then
            EnemyPokemon[i] = EnemyPokemon[i] .. PokeData
            break
        end
    end
end

--- This handles all the steps to allow players to trade.
local function _Tradescript()
    --Buffer 1 is enemy pokemon, 2 is our pokemon
    local Buffer1 = 33692880
    local Buffer2 = 33692912
    local Buffer3 = 33692932

    if TradeVars[1] == 0 and TradeVars[4] == 0 and TradeVars[3] == 0 and EnemyTradeVars[3] == 0 then
        OtherPlayerHasCancelled = 0
        TradeVars[3] = 1
        _Loadscript(4)
    elseif TradeVars[1] == 0 and TradeVars[4] == 0 and TradeVars[3] == 0 and EnemyTradeVars[3] > 0 then
        TradeVars[3] = 1
        TradeVars[4] = 1
        _Loadscript(14)
    elseif TradeVars[1] == 0 and TradeVars[4] == 0 and EnemyTradeVars[3] > 0 and TradeVars[3] > 0 then
        TradeVars[4] = 1
        _Loadscript(14)

        --	if TempVar2 == 0 then console:log("1: " .. TradeVars[1] .. " 8001: " .. Var8000[2] .. " OtherPlayerHasCancelled: " .. OtherPlayerHasCancelled .. " EnemyTradeVars[1]: " .. EnemyTradeVars[1]) end

        --Text is finished before trade
    elseif Var8000[2] ~= 0 and TradeVars[4] == 1 and TradeVars[1] == 0 then
        TradeVars[1] = 1
        TradeVars[2] = 0
        TradeVars[3] = 0
        TradeVars[4] = 0
        Var8000[1] = 0
        Var8000[2] = 0
        _Loadscript(12)

        --You have canceled or have not selected a valid pokemon slot
    elseif Var8000[2] == 1 and TradeVars[1] == 1 then
        _Loadscript(16)
        _SendToPlayer(PACKET_CANCEL_TRADE)
        LockFromScript = 0
        TradeVars[1] = 0
        TradeVars[2] = 0
        TradeVars[3] = 0
        --The other player has canceled
    elseif Var8000[2] == 2 and TradeVars[1] == 1 and OtherPlayerHasCancelled ~= 0 then
        OtherPlayerHasCancelled = 0
        _Loadscript(19)
        LockFromScript = 7
        TradeVars[1] = 0
        TradeVars[2] = 0
        TradeVars[3] = 0

        --You have finished your selection
    elseif Var8000[2] == 2 and TradeVars[1] == 1 and OtherPlayerHasCancelled == 0 then
        --You just finished. Display waiting
        TradeVars[3] = Var8000[5]
        TradeVars[5] = ReadBuffers(Buffer2, 4)
        --	TradeVars[6] = TradeVars[5] .. 5294967295
        --	WriteBuffers(Buffer1, TradeVars[6], 5)
        if EnemyTradeVars[1] == 2 then
            EnemyTradeVars[6] = EnemyTradeVars[5] .. 5294967295
            _WriteBuffers(Buffer1, EnemyTradeVars[6], 5)
            TradeVars[1] = 3
            _Loadscript(8)
        else
            _Loadscript(4)
            TradeVars[1] = 2
        end
    elseif TradeVars[1] == 2 then
        --Wait for other player
        if Var8000[2] ~= 0 then
            TradeVars[2] = 1
        end
        --If they cancel
        if Var8000[2] ~= 0 and OtherPlayerHasCancelled ~= 0 then
            OtherPlayerHasCancelled = 0
            _Loadscript(19)
            LockFromScript = 7
            TradeVars[1] = 0
            TradeVars[2] = 0
            TradeVars[3] = 0

            --If other player has finished selecting
        elseif Var8000[2] ~= 0 and ((EnemyTradeVars[2] == 1 and EnemyTradeVars[1] == 2) or EnemyTradeVars[1] == 3) then
            EnemyTradeVars[6] = EnemyTradeVars[5] .. 5294967295
            _WriteBuffers(Buffer1, EnemyTradeVars[6], 5)
            TradeVars[1] = 3
            TradeVars[2] = 0
            _Loadscript(8)

        end
    elseif TradeVars[1] == 3 then
        --If you decline
        if Var8000[2] == 1 then
            _SendToPlayer(PACKET_REFUSE_TRADE_OFFER)
            _Loadscript(16)
            LockFromScript = 7
            TradeVars[1] = 0
            TradeVars[2] = 0
            TradeVars[3] = 0

            --If you accept and they deny
        elseif Var8000[2] == 2 and OtherPlayerHasCancelled ~= 0 then
            OtherPlayerHasCancelled = 0
            _Loadscript(9)
            LockFromScript = 7
            TradeVars[1] = 0
            TradeVars[2] = 0
            TradeVars[3] = 0

            --If you accept and there is no denial
        elseif Var8000[2] == 2 and OtherPlayerHasCancelled == 0 then
            --If other player isn't finished selecting, wait. Otherwise, go straight into trade.
            if EnemyTradeVars[1] == 4 and EnemyTradeVars[2] == 2 then
                TradeVars[1] = 5
                TradeVars[2] = 2
                local TeamPos = EnemyTradeVars[3] + 1
                _SetEnemyPokemonTeam(TeamPos, 1)
                _Loadscript(17)
            else
                TradeVars[2] = 0
                _Loadscript(4)
                TradeVars[1] = 4
            end
        end
    elseif TradeVars[1] == 4 then
        --Wait for other player
        if Var8000[2] ~= 0 then
            TradeVars[2] = 2
        end
        --If they cancel
        if Var8000[2] ~= 0 and OtherPlayerHasCancelled ~= 0 then
            OtherPlayerHasCancelled = 0
            _Loadscript(19)
            LockFromScript = 7
            TradeVars[1] = 0
            TradeVars[2] = 0
            TradeVars[3] = 0

            --If other player has finished selecting
        elseif Var8000[2] ~= 0 and (EnemyTradeVars[2] == 2 or EnemyTradeVars[1] == 5) then
            TradeVars[2] = 2
            TradeVars[1] = 5
            local TeamPos = EnemyTradeVars[3] + 1
            _SetEnemyPokemonTeam(TeamPos, 1)
            _Loadscript(17)
        else
            --		console:log("VARS: " .. Var8000[2] .. " " .. EnemyTradeVars[2] .. " " .. EnemyTradeVars[1])
        end
    elseif TradeVars[1] == 5 then
        --Text for trade
        if Var8000[2] == 0 then
            _Loadscript(23)
            --After trade
        elseif Var8000[2] ~= 0 then
            TradeVars[1] = 0
            TradeVars[2] = 0
            TradeVars[3] = 0
            TradeVars[4] = 0
            TradeVars[5] = 0
            EnemyTradeVars[1] = 0
            EnemyTradeVars[2] = 0
            EnemyTradeVars[3] = 0
            EnemyTradeVars[4] = 0
            EnemyTradeVars[5] = 0
            LockFromScript = 0
        end
    end

    _SendRawTradeData()
end

-- RENDERING -----------------------------------------------------------------------------------------------------------
--- Create a table to track a remote player
local function NewPlayerProxy()
    local Proxy = {
        AnimationX=0,
        AnimationY=0,
        FutureX=0,
        FutureY=0,
        CurrentX=0,
        CurrentY=0,
        PreviousX=0,
        PreviousY=0,
        StartX=2000,
        StartY=2000,
        DifferentMapX=0,
        DifferentMapY=0,
        RelativeX=0,
        RelativeY=0,
        CurrentFacingDirection=0,
        FutureFacingDirection=0,
        --- The map this player is currently on
        CurrentMapID=0,
        --- The map this player was previously on
        PreviousID=0,
        --- How the current map was entered
        --- Presumably used to determine visibility with the previous map
        MapEntranceType=1,
        --- ???
        --- - Used to determine the x offset in calculating visibility (bike starts further to the left)
        --- - Used to determine the currently playing animation
        --- - Used to check movement method and set offsets for rendering
        --- - Padded to 3 characters in the packet
        PlayerExtra1=0,
        --- Sprite Number (Male / Female)
        Gender=0,
        --- How this player is moving (Walking / Biking / Surfing)
        MovementMethod=0,
        --- Used to determine whether to draw the battle symbol
        IsInBattle=0,
        --- Whether this player could be visible to us
        --- True if we either share map ids or previous map ids
        PlayerVis=0,
        --- A flag for whether this player recently changed maps
        MapChange=0,
        --- The current frame of the playing animation
        PlayerAnimationFrame=0,
        --- A value that oscillates between 0 and 1 each time the animation loops
        PlayerAnimationFrame2=0,
        --- The number of frames in this animation
        PlayerAnimationFrameMax=0,
        PreviousPlayerAnimation=0,
        --- The main sprite to draw.
        --- - The surfing pokemon when surfing
        --- - The player sprite in other cases
        SpriteID=0,
        --- The second sprite to draw.
        --- - The player sitting sprite when surfing.
        SpriteID2=0,
        --- The ID for the currently playing animation
        --- Used to choose the current sprites as well as lerp positon
        AnimateID=0
    }

    return Proxy
end

--- Calculate the related addresses for this rendering slot.
local function NewRenderer(index)
    local indexFromZero = index - 1
    local renderer = {
        isDirty=true,
        --- Start address. 100745216 = 06014000 = 184th tile. can safely use 32.
        --- CHANGE 100746752 = 190th tile = 2608
        --- Because the actual data doesn't start until 06013850, we will skip 50 hexbytes, or 80 decibytes
        spriteDataAddress=100746752 - (indexFromZero * 1280) + 80,
        spritePointerAddress=2608 - (indexFromZero * 40),
        --- This one originally had an if statement checking the game version.
        --- Keep this in mind if other games are eventually added.
        renderInstructionAddress=50345200 - (indexFromZero * 24)
    }
    Renderers[index] = renderer
end

--- Precalculate rendering addresses for this session.
local function CreateRenderers()
    for i = 1, MAX_RENDERED_PLAYERS do
        NewRenderer(i)
    end
end

--- Create an instruction to render the this data to the screen with this transform.
local function WriteRenderInstructionToMemory(renderer, offset, x, y, face, sprite, ex1, ex3, ex4)
    emu:write8(renderer.renderInstructionAddress  + offset,     y)
    emu:write8(renderer.renderInstructionAddress  + offset + 2, x)
    emu:write8(renderer.renderInstructionAddress  + offset + 3, face)
    emu:write8(renderer.renderInstructionAddress  + offset + 1, sprite)
    emu:write16(renderer.renderInstructionAddress + offset + 4, ex1)
    emu:write8(renderer.renderInstructionAddress  + offset + 6, ex3)
    emu:write8(renderer.renderInstructionAddress  + offset + 7, ex4)
end

--- Remove the render instruction, clearing the item from the screen.
local function EraseRenderInstructionFromMemory(renderer, offset)
    WriteRenderInstructionToMemory(
            renderer,
            offset,
            48,
            160,
            1,
            0,
            12,
            0,
            1
    )
end

--- Clears all rendered sprites for a given player.
--- - Layer 1 (normal sprite or surfing pokemon)
--- - Layer 2 (sitting sprite when surfing)
--- - Layer 3 (battle icon)
local function EraseAllPlayerRenderInstructions(renderer)
    --Base char
    EraseRenderInstructionFromMemory(renderer, 0)
    --Surfing char
    EraseRenderInstructionFromMemory(renderer, 8)
    --Extra Char
    EraseRenderInstructionFromMemory(renderer, 16)
end

--- Calls EraseAllPlayerRenderInstructions if the renderer has anything written to them.
--- Used to reduce unnecessary writes to memory.
local function EraseAllRenderInstructionsIfDirty(renderer)
    if renderer.isDirty then
        renderer.isDirty = false
        EraseAllPlayerRenderInstructions(renderer)
    end
end

--- Determine whether the given player is within the screenspace -
--- either on this map, or an adjacent one.
local function _UpdatePlayerVisibility(player)
    local MinX = -16
    local MaxX = 240
    local MinY = -32
    local MaxY = 144
    -- First, we check whether a player is on this or a map we know to be adjacent.
    -- If this player is on the same map as us
    if LocalPlayerMapID == player.CurrentMapID then
        player.DifferentMapX = 0
        player.DifferentMapY = 0
        player.MapChange = 0
    -- If this player is on a map we know to be adjacent to the one we are on
    elseif (LocalPlayerMapIDPrev == player.CurrentMapID or LocalPlayerMapID == player.PreviousMapID) and player.MapEntranceType == 0 then
        if player.MapChange == 1 then
            player.DifferentMapX = ((player.PreviousX - player.StartX) * 16)
            player.DifferentMapY = ((player.PreviousY - player.StartY) * 16)
        end
    else
        player.PlayerVis = 0
        player.DifferentMapX = 0
        player.DifferentMapY = 0
        player.MapChange = 0
        return
    end

    if LocalPlayerMapEntranceType == 0 and (LocalPlayerMapIDPrev == player.CurrentMapID or LocalPlayerMapID == player.PreviousMapID) and player.MapChange == 0 then
        --AnimationX is -16 - 16 and is purely to animate sprites
        --CameraX can be between -16 and 16 and is to get the camera movement while moving
        --Current X is the X the current sprite has
        --Player X is the X the player sprite has
        --112 and 56 = middle of screen
        player.RelativeX = player.AnimationX + CameraX + ((player.CurrentX - LocalPlayerCurrentX) * 16) + player.DifferentMapX + LocalPlayerDifferentMapX + 112
        player.RelativeY = player.AnimationY + CameraY + ((player.CurrentY - LocalPlayerCurrentY) * 16) + player.DifferentMapY + LocalPlayerDifferentMapY + 56
    else
        player.RelativeX = player.AnimationX + CameraX + ((player.CurrentX - LocalPlayerCurrentX) * 16) + player.DifferentMapX + 112
        player.RelativeY = player.AnimationY + CameraY + ((player.CurrentY - LocalPlayerCurrentY) * 16) + player.DifferentMapY + 56
    end

    -- Next, we check whether the player is within our screen space
    --This is for the bike + surf
    if player.PlayerExtra1 >= 17 and player.PlayerExtra1 <= 40 then
        MinX = -8
    -- FIXME: never used. The range of 33-40 is completely within the range of 17-40
    elseif player.PlayerExtra1 >= 33 and player.PlayerExtra1 <= 40 then
        MinX = 8
    else
        MinX = -16
    end

    if player.RelativeX > MaxX or player.RelativeX < MinX or player.RelativeY > MaxY or player.RelativeY < MinY then
        player.PlayerVis = 0
    else
        player.PlayerVis = 1
    end
end

--- Uses the player's currently playing animation to extrapolate position.
--- Assumes the next position is 1 tile (16px) away.
---
--- The current implementation seems to iterate an animation frame number,
--- and then update the `animation` position by a hardcoded amount on specific frames within the animation.
--- When the `animation` position is a full tile from zero (>15, <-15), the position is updated by one tile in that direction.
---
--- Ultimately, a more general time-based interpolation might be more suitable and handle varying framerates a little better.
--- We know how much time elapses between packets, so all we need to do is interpolate from one packet's position to the next.
local function _AnimatePlayerMovement(player)
    -- TODO: optimization: Don't lerp sprites that are completely offscreen. Just update them directly.

    --This is for updating the previous coords with new ones, without looking janky
    --AnimateID List
    --0 = Standing Still
    --1 = Walking Down
    --2 = Walking Up
    --3 = Walking Left/Right
    --4 = Running Down
    --5 = Running Up
    --6 = Running Left/Right
    --7 = Bike Down
    --8 = Bike Up
    --9 = Bike left/right
    --10 = Face down
    --11 = Face up
    --12 = Face left/right

    -- On the first packet, just snap them to their positions
    if player.CurrentX == 0 then
        player.CurrentX = player.FutureX
    end
    if player.CurrentY == 0 then
        player.CurrentY = player.FutureY
    end

    local AnimateID = player.AnimateID
    local AnimationMovementX = player.FutureX - player.CurrentX
    local AnimationMovementY = player.FutureY - player.CurrentY

    if player.PlayerAnimationFrame < 0 then
        player.PlayerAnimationFrame = 0
    end
    player.PlayerAnimationFrame = player.PlayerAnimationFrame + 1

    --Animate left movement
    if AnimationMovementX < 0 then

        --Walk
        if AnimateID == 3 then
            player.PlayerAnimationFrameMax = 14
            player.AnimationX = player.AnimationX - 1
            if player.PlayerAnimationFrame == 5 then
                player.AnimationX = player.AnimationX - 1
            end
            if player.PlayerAnimationFrame == 9 then
                player.AnimationX = player.AnimationX - 1
            end
            if player.PlayerAnimationFrame >= 3 and player.PlayerAnimationFrame <= 11 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 4
                else
                    player.SpriteID1 = 5
                end
            else
                player.SpriteID1 = 1
            end
            --Run
        elseif AnimateID == 6 then
            player.PlayerAnimationFrameMax = 9
            player.AnimationX = player.AnimationX - 4
            --	console:log("Frame: " .. PlayerAnimationFrame)
            if player.PlayerAnimationFrame > 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 20
                else
                    player.SpriteID1 = 21
                end
            else
                player.SpriteID1 = 19
            end
            --Bike
        elseif AnimateID == 9 then
            player.PlayerAnimationFrameMax = 6
            player.AnimationX = player.AnimationX + ((AnimationMovementX * 16) / 3)
            if player.PlayerAnimationFrame >= 1 and player.PlayerAnimationFrame < 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 13
                else
                    player.SpriteID1 = 14
                end
            else
                player.SpriteID1 = 10
            end
            --Surf
        elseif AnimateID == 23 then
            player.PlayerAnimationFrameMax = 4
            player.AnimationX = player.AnimationX - 4
            player.SpriteID1 = 30
            player.SpriteID2 = 36
        end

        --Animate right movement
    elseif AnimationMovementX > 0 then
        if AnimateID == 13 then
            player.PlayerAnimationFrameMax = 14
            player.AnimationX = player.AnimationX + 1
            if player.PlayerAnimationFrame == 5 then
                player.AnimationX = player.AnimationX + 1
            end
            if player.PlayerAnimationFrame == 9 then
                player.AnimationX = player.AnimationX + 1
            end
            if player.PlayerAnimationFrame >= 3 and player.PlayerAnimationFrame <= 11 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 4
                else
                    player.SpriteID1 = 5
                end
            else
                player.SpriteID1 = 1
            end
        elseif AnimateID == 14 then
            player.PlayerAnimationFrameMax = 9
            player.AnimationX = player.AnimationX + 4
            if player.PlayerAnimationFrame > 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 20
                else
                    player.SpriteID1 = 21
                end
            else
                player.SpriteID1 = 19
            end
        elseif AnimateID == 15 then
            --	console:log("Bike")
            player.PlayerAnimationFrameMax = 6
            player.AnimationX = player.AnimationX + ((AnimationMovementX * 16) / 3)
            if player.PlayerAnimationFrame >= 1 and player.PlayerAnimationFrame < 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 13
                else
                    player.SpriteID1 = 14
                end
            else
                player.SpriteID1 = 10
            end
            --Surf
        elseif AnimateID == 24 then
            player.PlayerAnimationFrameMax = 4
            player.AnimationX = player.AnimationX + 4
            player.SpriteID1 = 30
            player.SpriteID2 = 36
        else

        end
    else
        player.AnimationX = 0
        player.CurrentX = player.FutureX
        --Turn player left/right
        if AnimateID == 12 then
            player.PlayerAnimationFrameMax = 8
            if player.PlayerAnimationFrame > 1 and player.PlayerAnimationFrame < 6 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 4
                else
                    player.SpriteID1 = 5
                end
            else
                player.SpriteID1 = 1
            end
            --If they are now equal
        end
        --Surfing animation
        if AnimateID == 19 then
            player.SpriteID2 = 36
            if player.PreviousPlayerAnimation ~= 19 then
                player.PlayerAnimationFrame2 = 0
                player.PlayerAnimationFrame = 24
            end
            player.PlayerAnimationFrameMax = 48
            if player.PlayerAnimationFrame2 == 0 then
                player.SpriteID1 = 30
            elseif player.PlayerAnimationFrame2 == 1 then
                player.SpriteID1 = 33
            end
        elseif AnimateID == 20 then
            player.SpriteID2 = 36
            if player.PreviousPlayerAnimation ~= 20 then
                player.PlayerAnimationFrame2 = 0
                player.PlayerAnimationFrame = 24
            end
            player.PlayerAnimationFrameMax = 48
            if player.PlayerAnimationFrame2 == 0 then
                player.SpriteID1 = 30
            elseif player.PlayerAnimationFrame2 == 1 then
                player.SpriteID1 = 33
            end
        end
    end


    --Animate up movement
    if AnimationMovementY < 0 then
        if AnimateID == 2 then
            player.PlayerAnimationFrameMax = 14
            player.AnimationY = player.AnimationY - 1
            if player.PlayerAnimationFrame == 5 then
                player.AnimationY = player.AnimationY - 1
            end
            if player.PlayerAnimationFrame == 9 then
                player.AnimationY = player.AnimationY - 1
            end
            if player.PlayerAnimationFrame >= 3 and player.PlayerAnimationFrame <= 11 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 6
                else
                    player.SpriteID1 = 7
                end
            else
                player.SpriteID1 = 2
            end
        elseif AnimateID == 5 then
            player.PlayerAnimationFrameMax = 9
            player.AnimationY = player.AnimationY - 4
            if player.PlayerAnimationFrame > 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 23
                else
                    player.SpriteID1 = 24
                end
            else
                player.SpriteID1 = 22
            end
        elseif AnimateID == 8 then
            player.PlayerAnimationFrameMax = 6
            player.AnimationY = player.AnimationY + ((AnimationMovementY * 16) / 3)
            if player.PlayerAnimationFrame >= 1 and player.PlayerAnimationFrame < 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 15
                else
                    player.SpriteID1 = 16
                end
            else
                player.SpriteID1 = 11
            end
            --Surf
        elseif AnimateID == 22 then
            player.PlayerAnimationFrameMax = 4
            player.AnimationY = player.AnimationY - 4
            player.SpriteID1 = 29
            player.SpriteID2 = 35
        end

        --Animate down movement
    elseif AnimationMovementY > 0 then
        if AnimateID == 1 then
            player.PlayerAnimationFrameMax = 14
            player.AnimationY = player.AnimationY + 1
            if player.PlayerAnimationFrame == 5 then
                player.AnimationY = player.AnimationY + 1
            end
            if player.PlayerAnimationFrame == 9 then
                player.AnimationY = player.AnimationY + 1
            end
            if player.PlayerAnimationFrame >= 3 and player.PlayerAnimationFrame <= 11 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 8
                else
                    player.SpriteID1 = 9
                end
            else
                player.SpriteID1 = 3
            end
        elseif AnimateID == 4 then
            player.PlayerAnimationFrameMax = 9
            player.AnimationY = player.AnimationY + 4
            if player.PlayerAnimationFrame > 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 26
                else
                    player.SpriteID1 = 27
                end
            else
                player.SpriteID1 = 25
            end
        elseif AnimateID == 7 then
            player.PlayerAnimationFrameMax = 6
            player.AnimationY = player.AnimationY + ((AnimationMovementY * 16) / 3)
            if player.PlayerAnimationFrame >= 1 and player.PlayerAnimationFrame < 5 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 17
                else
                    player.SpriteID1 = 18
                end
            else
                player.SpriteID1 = 12
            end
            --Surf
        elseif AnimateID == 21 then
            player.PlayerAnimationFrameMax = 4
            player.AnimationY = player.AnimationY + 4
            player.SpriteID1 = 28
            player.SpriteID2 = 34
            --If they are now equal
        end
    else
        player.AnimationY = 0
        player.CurrentY = player.FutureY
        --Turn player down
        if AnimateID == 10 then
            player.PlayerAnimationFrameMax = 8
            if player.PlayerAnimationFrame > 1 and player.PlayerAnimationFrame < 6 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 8
                else
                    player.SpriteID1 = 9
                end
            else
                player.SpriteID1 = 3
            end
            --Turn player up

        elseif AnimateID == 11 then
            player.PlayerAnimationFrameMax = 8
            if player.PlayerAnimationFrame > 1 and player.PlayerAnimationFrame < 6 then
                if player.PlayerAnimationFrame2 == 0 then
                    player.SpriteID1 = 6
                else
                    player.SpriteID1 = 7
                end
            else
                player.SpriteID1 = 2
            end
        else
            --		createChars(3,SpriteNumber)
        end

        --Surfing animation
        if AnimateID == 17 then
            player.SpriteID2 = 34
            if player.PreviousPlayerAnimation ~= 17 then
                player.PlayerAnimationFrame2 = 0
                player.PlayerAnimationFrame = 24
            end
            player.PlayerAnimationFrameMax = 48
            if player.PlayerAnimationFrame2 == 0 then
                player.SpriteID1 = 28
            elseif player.PlayerAnimationFrame2 == 1 then
                player.SpriteID1 = 31
            end
        elseif AnimateID == 18 then
            player.SpriteID2 = 35
            if player.PreviousPlayerAnimation ~= 18 then
                player.PlayerAnimationFrame2 = 0
                player.PlayerAnimationFrame = 24
            end
            player.PlayerAnimationFrameMax = 48
            if player.PlayerAnimationFrame2 == 0 then
                player.SpriteID1 = 29
            elseif player.PlayerAnimationFrame2 == 1 then
                player.SpriteID1 = 32
            end
            --If they are now equal
        end
    end

    if AnimateID == 251 then
        player.PlayerAnimationFrame = 0
        player.AnimationX = 0
        player.AnimationY = 0
        player.CurrentX = player.FutureX
        player.CurrentY = player.FutureY
    elseif AnimateID == 252 then
        player.PlayerAnimationFrame = 0
        player.AnimationX = 0
        player.AnimationY = 0
        player.CurrentX = player.FutureX
        player.CurrentY = player.FutureY
    elseif AnimateID == 253 then
        player.PlayerAnimationFrame = 0
        player.AnimationX = 0
        player.AnimationY = 0
        player.CurrentX = player.FutureX
        player.CurrentY = player.FutureY
    elseif AnimateID == 254 then
        player.PlayerAnimationFrame = 0
        player.AnimationX = 0
        player.AnimationY = 0
        player.CurrentX = player.FutureX
        player.CurrentY = player.FutureY
    elseif AnimateID == 255 then
        player.CurrentX = player.FutureX
        player.CurrentY = player.FutureY
    end

    if player.PlayerAnimationFrameMax <= player.PlayerAnimationFrame then
        player.PlayerAnimationFrame = 0
        if player.PlayerAnimationFrame2 == 0 then
            player.PlayerAnimationFrame2 = 1
        else
            player.PlayerAnimationFrame2 = 0
        end
    end
    if player.AnimationX > 15 then
        player.CurrentX = player.CurrentX + 1
        player.AnimationX = player.AnimationX - 16
    elseif player.AnimationX < -15 then
        player.CurrentX = player.CurrentX - 1
        player.AnimationX = player.AnimationX + 16
    end
    if player.AnimationY > 15 then
        player.CurrentY = player.CurrentY + 1
        player.AnimationY = player.AnimationY - 16
    elseif player.AnimationY < -15 then
        player.CurrentY = player.CurrentY - 1
        player.AnimationY = player.AnimationY + 16
    end
    player.PreviousPlayerAnimation = AnimateID
end

--- Parses received sprite data into local variables
--- Determine AnimationID
local function _HandleSprites(player)
    --Because handling images every time would become a hassle, this will automatically set the image of every player

    --PlayerExtra 1 = Down Face
    --PlayerExtra 2 = Up Face
    --PlayerExtra 3 or 4 = Left/Right Face
    --PlayerExtra 5 = Down Walk
    --PlayerExtra 6 = Up Walk
    --PlayerExtra 7 or 8 = Left/Right Walk
    --PlayerExtra 9 = Down Turn
    --PlayerExtra 10 = Up Turn
    --PlayerExtra 11 or 12 = Left/Right Turn
    --PlayerExtra 13 = Down Run
    --PlayerExtra 14 = Up Run
    --PlayerExtra 15 or 16 = Left/Right Run
    --PlayerExtra 17 = Down Bike
    --PlayerExtra 18 = Up Bike
    --PlayerExtra 19 or 20 = Left/Right Bike
    --Facing down

    if player.PlayerExtra1 == 1 then
        player.SpriteID1 = 3
        player.CurrentFacingDirection = 4
        player.AnimateID = 251

        --Facing up
    elseif player.PlayerExtra1 == 2 then
        player.SpriteID1 = 2
        player.CurrentFacingDirection = 3
        player.AnimateID = 252

        --Facing left
    elseif player.PlayerExtra1 == 3 then
        player.SpriteID1 = 1
        player.CurrentFacingDirection = 1
        player.AnimateID = 253

        --Facing right
    elseif player.PlayerExtra1 == 4 then
        player.SpriteID1 = 1
        player.CurrentFacingDirection = 2
        player.AnimateID = 254

        --walk down
    elseif player.PlayerExtra1 == 5 then
        player.CurrentFacingDirection = 4
        player.AnimateID = 1

        --walk up
    elseif player.PlayerExtra1 == 6 then
        player.CurrentFacingDirection = 3
        player.AnimateID = 2

        --walk left
    elseif player.PlayerExtra1 == 7 then
        player.CurrentFacingDirection = 1
        player.AnimateID = 3

        --walk right
    elseif player.PlayerExtra1 == 8 then
        player.CurrentFacingDirection = 2
        player.AnimateID = 13

        --turn down
    elseif player.PlayerExtra1 == 9 then
        player.CurrentFacingDirection = 4
        player.AnimateID = 10

        --turn up
    elseif player.PlayerExtra1 == 10 then
        player.CurrentFacingDirection = 3
        player.AnimateID = 11

        --turn left
    elseif player.PlayerExtra1 == 11 then
        player.CurrentFacingDirection = 1
        player.AnimateID = 12

        --turn right
    elseif player.PlayerExtra1 == 12 then
        player.CurrentFacingDirection = 2
        player.AnimateID = 12

        --run down
    elseif player.PlayerExtra1 == 13 then
        player.CurrentFacingDirection = 4
        player.AnimateID = 4

        --run up
    elseif player.PlayerExtra1 == 14 then
        player.CurrentFacingDirection = 3
        player.AnimateID = 5

        --run left
    elseif player.PlayerExtra1 == 15 then
        player.CurrentFacingDirection = 1
        player.AnimateID = 6

        --run right
    elseif player.PlayerExtra1 == 16 then
        player.CurrentFacingDirection = 2
        player.AnimateID = 14

        --bike face down
    elseif player.PlayerExtra1 == 17 then
        player.SpriteID1 = 12
        player.CurrentFacingDirection = 4
        player.AnimateID = 251

        --bike face up
    elseif player.PlayerExtra1 == 18 then
        player.SpriteID1 = 11
        player.CurrentFacingDirection = 3
        player.AnimateID = 252

        --bike face left
    elseif player.PlayerExtra1 == 19 then
        player.SpriteID1 = 10
        player.CurrentFacingDirection = 1
        player.AnimateID = 253

        --bike face right
    elseif player.PlayerExtra1 == 20 then
        player.SpriteID1 = 10
        player.CurrentFacingDirection = 2
        player.AnimateID = 254

        --bike move down
    elseif player.PlayerExtra1 == 21 then
        player.CurrentFacingDirection = 4
        player.AnimateID = 7

        --bike move up
    elseif player.PlayerExtra1 == 22 then
        player.CurrentFacingDirection = 3
        player.AnimateID = 8

        --bike move left
    elseif player.PlayerExtra1 == 23 then
        player.CurrentFacingDirection = 1
        player.AnimateID = 9

        --bike move right
    elseif player.PlayerExtra1 == 24 then
        player.CurrentFacingDirection = 2
        player.AnimateID = 15

        --bike fast move down
    elseif player.PlayerExtra1 == 25 then
        player.CurrentFacingDirection = 4
        player.AnimateID = 7

        --bike fast move up
    elseif player.PlayerExtra1 == 26 then
        player.CurrentFacingDirection = 3
        player.AnimateID = 8

        --bike fast move left
    elseif player.PlayerExtra1 == 27 then
        player.CurrentFacingDirection = 1
        player.AnimateID = 9

        --bike fast move right
    elseif player.PlayerExtra1 == 28 then
        player.CurrentFacingDirection = 2
        player.AnimateID = 15

        --bike hit wall down
    elseif player.PlayerExtra1 == 29 then
        player.SpriteID1 = 12
        player.CurrentFacingDirection = 4
        player.AnimateID = 251

        --bike hit wall up
    elseif player.PlayerExtra1 == 30 then
        player.SpriteID1 = 11
        player.CurrentFacingDirection = 3
        player.AnimateID = 252

        --bike hit wall left
    elseif player.PlayerExtra1 == 31 then
        player.SpriteID1 = 10
        player.CurrentFacingDirection = 1
        player.AnimateID = 253

        --bike hit wall right
    elseif player.PlayerExtra1 == 32 then
        player.SpriteID1 = 10
        player.CurrentFacingDirection = 2
        player.AnimateID = 254

        --Surfing

        --Facing down
    elseif player.PlayerExtra1 == 33 then
        player.CurrentFacingDirection = 4
        player.AnimateID = 17

        --Facing up
    elseif player.PlayerExtra1 == 34 then
        player.CurrentFacingDirection = 3
        player.AnimateID = 18

        --Facing left
    elseif player.PlayerExtra1 == 35 then
        player.CurrentFacingDirection = 1
        player.AnimateID = 19

        --Facing right
    elseif player.PlayerExtra1 == 36 then
        player.CurrentFacingDirection = 2
        player.AnimateID = 20

        --surf down
    elseif player.PlayerExtra1 == 37 then
        player.CurrentFacingDirection = 4
        player.AnimateID = 21

        --surf up
    elseif player.PlayerExtra1 == 38 then
        player.CurrentFacingDirection = 3
        player.AnimateID = 22

        --surf left
    elseif player.PlayerExtra1 == 39 then
        player.CurrentFacingDirection = 1
        player.AnimateID = 23

        --surf right
    elseif player.PlayerExtra1 == 40 then
        player.CurrentFacingDirection = 2
        player.AnimateID = 24


        --default position
    elseif player.PlayerExtra1 == 0 then
        player.AnimateID = 255

    end
end

--- Calculate our screen space so we can determine which players are visible.
local function _CalculateCamera()
    --	console:log("Player X camera: " .. PlayerMapXMove .. "Player Y camera: " .. PlayerMapYMove)
    --	console:log("PlayerMapXMove: " .. PlayerMapXMove .. "PlayerMapYMove: " .. PlayerMapYMove .. "PlayerMapXMovePREV: " .. PlayerMapXMovePrev .. "PlayerMapYMovePrev: " .. PlayerMapYMovePrev)

    local PlayerMapXMoveTemp = 0
    local PlayerMapYMoveTemp = 0

    --if PlayerMapChange == 1 then
    --Update first if map change
    LocalPlayerMapXMovePrev = emu:read16(33687132) - 8
    LocalPlayerMapYMovePrev = emu:read16(33687134)
    PlayerMapXMoveTemp = LocalPlayerMapXMovePrev % 16
    PlayerMapYMoveTemp = LocalPlayerMapYMovePrev % 16

    if LocalPlayerCurrentDirection == 1 then
        CameraX = PlayerMapXMoveTemp * -1
        --	console:log("XTEMP: " .. PlayerMapXMoveTemp)
    elseif LocalPlayerCurrentDirection == 2 then
        if PlayerMapXMoveTemp > 0 then
            CameraX = 16 - PlayerMapXMoveTemp
        else
            CameraX = 0
        end
        --console:log("XTEMP: " .. PlayerMapXMoveTemp)
    elseif LocalPlayerCurrentDirection == 3 then
        CameraY = PlayerMapYMoveTemp * -1
        --console:log("YTEMP: " .. PlayerMapYMoveTemp)
    elseif LocalPlayerCurrentDirection == 4 then
        --console:log("YTEMP: " .. PlayerMapYMoveTemp)
        if PlayerMapYMoveTemp > 0 then
            CameraY = 16 - PlayerMapYMoveTemp
        else
            CameraY = 0
        end
    end

    --Calculations for X and Y of new map
    if LocalPlayerMapChange == 1 and (CameraX == 0 and CameraY == 0) then
        LocalPlayerMapChange = 0
        LocalPlayerStartX = LocalPlayerCurrentX
        LocalPlayerStartY = LocalPlayerCurrentY
        LocalPlayerDifferentMapX = (LocalPlayerStartX - LocalPlayerPreviousX) * 16
        LocalPlayerDifferentMapY = (LocalPlayerStartY - LocalPlayerPreviousY) * 16
        if LocalPlayerCurrentDirection == 1 then
            LocalPlayerStartX = LocalPlayerStartX + 1
        elseif LocalPlayerCurrentDirection == 2 then
            LocalPlayerStartX = LocalPlayerStartX - 1
        elseif LocalPlayerCurrentDirection == 3 then
            LocalPlayerStartY = LocalPlayerStartY + 1
        elseif LocalPlayerCurrentDirection == 4 then
            LocalPlayerStartY = LocalPlayerStartY - 1
        end
    end
end

--- Load the sprite data into memory and add an instruction to render it.
local function _RenderPlayer(player, renderer)
    EraseAllRenderInstructionsIfDirty(renderer)

    local isBiking = 0
    local isSurfing = 0

    local FinalMapX = player.RelativeX
    local FinalMapY = player.RelativeY

    --Flip sprite if facing right
    local FacingTemp = 128
    if player.CurrentFacingDirection == 2 then
        FacingTemp = 144
    else
        FacingTemp = 128
    end

    -- Biking
    if player.PlayerExtra1 >= 17 and player.PlayerExtra1 <= 32 then
        isBiking = 1
        FinalMapX = FinalMapX - 8
        WriteIntegerArrayToEmu(renderer.spriteDataAddress - 80, FRLG.Sprites[player.Gender][player.SpriteID1])
        WriteRenderInstructionToMemory(renderer, 0, FinalMapX, FinalMapY, FacingTemp, 0, renderer.spritePointerAddress, 0, 0)

    -- Surfing
    elseif player.PlayerExtra1 >= 33 and player.PlayerExtra1 <= 40 then
        isSurfing = 1
        if player.PlayerAnimationFrame2 == 1 and player.PlayerExtra1 <= 36 then
            FinalMapY = FinalMapY + 1
        end
        --Surfing char
        WriteIntegerArrayToEmu(renderer.spriteDataAddress + 512, FRLG.Sprites[player.Gender][player.SpriteID1])
        WriteRenderInstructionToMemory(renderer, 0, FinalMapX, FinalMapY, FacingTemp, 128, renderer.spritePointerAddress, 0, 0)

        if player.PlayerAnimationFrame2 == 1 and player.PlayerExtra1 <= 36 then
            FinalMapY = FinalMapY - 1
        end
        FinalMapX = FinalMapX - 8
        FinalMapY = FinalMapY + 8
        --Sitting char
        WriteIntegerArrayToEmu(renderer.spriteDataAddress - 20, FRLG.Sprites[player.Gender][player.SpriteID2])
        WriteRenderInstructionToMemory(renderer,  8, FinalMapX, FinalMapY, FacingTemp, 0, renderer.spritePointerAddress + 18, 0, 0)

    --Player default
    else
        WriteIntegerArrayToEmu(renderer.spriteDataAddress, FRLG.Sprites[player.Gender][player.SpriteID1])
        WriteRenderInstructionToMemory(renderer, 0, FinalMapX, FinalMapY, FacingTemp, 128, renderer.spritePointerAddress, 0, 0)
    end

    -- Add an icon above the head if needed.
    if player.IsInBattle == 1 then
        local SymbolY = FinalMapY - 8
        local SymbolX = FinalMapX
        local spritePointer = renderer.spritePointerAddress + 8
        if isBiking == 1 then
            spritePointer = renderer.spritePointerAddress + 16
            SymbolX = FinalMapX + 8
        elseif isSurfing == 1 then
            SymbolY = FinalMapY - 16
            SymbolX = FinalMapX + 8
        end
        WriteIntegerArrayToEmu(renderer.spriteDataAddress + 256 + (isBiking * 256) - 80, FRLG.Sprites[2][1])
        WriteRenderInstructionToMemory(renderer, 16, SymbolX, SymbolY, 64, 0, spritePointer, 0, 1)
     end
    renderer.isDirty = true
end

--- This parses the payload and updates the values for a remote player that we are tracking.
local function _OnRemotePlayerUpdate(player, payload)
    -- Four free bytes
    local x               = tonumber(string.sub(payload,  5,  8)) - 2000
    local y               = tonumber(string.sub(payload,  9, 12)) - 2000
    -- Three free bytes
    player.PlayerExtra1   = tonumber(string.sub(payload, 16, 18)) - 100
    local gender          = tonumber(string.sub(payload, 19, 19))
    player.MovementMethod = tonumber(string.sub(payload, 20, 20))
    player.IsInBattle     = tonumber(string.sub(payload, 21, 21))
    local map             = tonumber(string.sub(payload, 22, 27)) - 100000
    local prevMap         = tonumber(string.sub(payload, 28, 33)) - 100000
    local mapEntranceType = tonumber(string.sub(payload, 34, 34))
    player.StartX         = tonumber(string.sub(payload, 35, 38)) - 2000
    player.StartY         = tonumber(string.sub(payload, 39, 42)) - 2000
    -- One free byte

    if player.CurrentMapID ~= map  then
        player.PlayerAnimationFrame = 0
        player.PlayerAnimationFrame2 = 0
        player.PlayerAnimationFrameMax = 0
        player.CurrentMapID = map
        player.PreviousMapID = prevMap
        player.MapEntranceType = mapEntranceType
        -- Set the position of where they were last on their previous map
        player.PreviousX = player.CurrentX
        player.PreviousY = player.CurrentY
        -- The future position and current position will be the same briefly
        player.CurrentX = x
        player.CurrentY = y
        -- A flag indicating that this player has recently changed maps
        player.MapChange = 1

        -- TODO: this would be a great place to update map offsets and/or relative positions
    end
    -- Where the player should animate toward
    player.FutureX = x
    player.FutureY = y

    if DEBUG_GENDER_SWITCH then
        player.Gender = 1 - gender
    else
        player.Gender = gender
    end

    -- Determine current state from sprite
    _HandleSprites(player)
end

-- GET CURRENT STATE ---------------------------------------------------------------------------------------------------

--- This reads several memory addresses relating to user input
--- and advances the loaded scripts to the next in series.
local function _DoScriptUpdates()
    for key, adr in pairs(Var8000Adr) do
        Var8000[key] = tonumber(emu:read16(adr))
    end

    --BATTLE/TRADE--

    --	if TempVar2 == 0 then console:log("OtherPlayerCanceled: " .. OtherPlayerHasCancelled) end

    --If you cancel/stop
    if LockFromScript == 0 then
        TargetPlayer = "00000000"
    end

    --Wait until other player accepts battle
    if LockFromScript == 4 then
        if Var8000[2] ~= 0 then
            if TextSpeedWait == 1 then
                TextSpeedWait = 0
                LockFromScript = 8
                _Loadscript(13)
            elseif TextSpeedWait == 3 then
                TextSpeedWait = 0
                LockFromScript = 7
                _Loadscript(11)
            elseif TextSpeedWait == 5 then
                TextSpeedWait = 0
                LockFromScript = 7
                _Loadscript(20)
            end
        end
        --				SendToPlayer(PACKET_REQUEST_BATTLE)

        --Wait until other player accepts trade
    elseif LockFromScript == 5 then
        if Var8000[2] ~= 0 then
            if TextSpeedWait == 2 then
                TextSpeedWait = 0
                LockFromScript = 9
            elseif TextSpeedWait == 4 then
                TextSpeedWait = 0
                LockFromScript = 7
                _Loadscript(7)
            elseif TextSpeedWait == 6 then
                TextSpeedWait = 0
                LockFromScript = 7
                _Loadscript(21)
            end
        end
        --				SendToPlayer(PACKET_REQUEST_TRADE)

        --Show card. Placeholder for now
    elseif LockFromScript == 6 then
        if Var8000[2] ~= 0 then
            --		console:log("Var 8001: " .. Var8000[2])
            LockFromScript = 0
            --	then SendToPlayer(PACKET_REQUEST_TRADE)
        end

        --Exit message
    elseif LockFromScript == 7 then
        if Var8000[2] ~= 0 then
            LockFromScript = 0
            Keypressholding = 1
        end

        --Trade script
    elseif LockFromScript == 8 then

        _Battlescript()

        --Battle script
    elseif LockFromScript == 9 then

        _Tradescript()

        --Player 1 has requested to battle
    elseif LockFromScript == 10 then
        --	if Var8000[2] ~= 0 then console:log("Var8001: " .. Var8000[2]) end
        if Var8000[2] == 2 then
            if OtherPlayerHasCancelled == 0 then
                _RequestRawPokemonData()
                _SendToPlayer(PACKET_ACCEPT_BATTLE)
                LockFromScript = 8
                _Loadscript(13)
            else
                OtherPlayerHasCancelled = 0
                LockFromScript = 7
                _Loadscript(18)
            end
        elseif Var8000[2] == 1 then
            LockFromScript = 0
            _SendToPlayer(PACKET_DECLINE_BATTLE)
            Keypressholding = 1
        end

        --Player 1 has requested to trade
    elseif LockFromScript == 11 then
        --	if Var8000[2] ~= 0 then console:log("Var8001: " .. Var8000[2]) end
        --If accept, then send that you accept
        if Var8000[2] == 2 then
            if OtherPlayerHasCancelled == 0 then
                _RequestRawPokemonData()
                _SendToPlayer(PACKET_ACCEPT_TRADE)
                LockFromScript = 9
            else
                OtherPlayerHasCancelled = 0
                LockFromScript = 7
                _Loadscript(19)
            end
        elseif Var8000[2] == 1 then
            LockFromScript = 0
            _SendToPlayer(PACKET_DECLINE_TRADE)
            Keypressholding = 1
        end
    end
end

--- Gets the map id and location on that map.
local function _GetPosition()
    LocalPlayerMapIDPrev = emu:read16(33813418)
    if LocalPlayerMapIDPrev == LocalPlayerMapID then
        LocalPlayerPreviousX = LocalPlayerCurrentX
        LocalPlayerPreviousY = LocalPlayerCurrentY
        LocalPlayerMapEntranceType = emu:read8(33785351)
        if LocalPlayerMapEntranceType > 10 then
            LocalPlayerMapEntranceType = 9
        end
        LocalPlayerMapChange = 1
    end
    LocalPlayerMapID    = emu:read16(33813416)
    LocalPlayerCurrentX = emu:read16(33779272)
    LocalPlayerCurrentY = emu:read16(33779274)
end

--- Reads the currently displayed sprite and
--- decodes it into more granular information.
--- - Gender
--- - CurrentFacingDirection
--- - Animation
local function _GetSpriteData()
    local PlayerAction  = emu:read8(33779284)

    -- Decode current sprite data
    local Bike = emu:read16(33687112)
    if Bike > 3000 then Bike = Bike + BikeOffset end
    local DecodedBikeAction  = FRLG.BikeDecoder[Bike]

    if DecodedBikeAction ~= nil then
        LocalPlayerGender         = DecodedBikeAction[1]
        LocalPlayerMovementMethod = DecodedBikeAction[2]
        local DecodedMovement     = FRLG.MovementDecoder[LocalPlayerMovementMethod][PlayerAction]
        if DecodedMovement ~= nil then
            LocalPlayerCurrentDirection = DecodedMovement[1]
            LocalPlayerExtra1 = DecodedMovement[2 + ShouldDrawRemotePlayers]
        end
    end

    -- This was in a block for MovementMethod = MOVEMENT_ON_FOOT and ShouldDrawRemotePlayers == 1
    -- if PlayerAction == 255 then PlayerExtra1 = 0 end
end

--- Checks the state of the screen for whether remote players would even be visible
local function _GetScreenState()
    -- TODO: Figure out what this is and rename it.
    local ScreenData1 = emu:read32(33691280)
    local IntroScreenData = emu:read8(33686716)
    local BattleScreenData = emu:read8(33685514)

    if (IntroScreenData ~= 80 or (ScreenData1 > 0)) and (LockFromScript == 0 or LockFromScript == 8 or LockFromScript == 9) then
        ShouldDrawRemotePlayers = 0
    else
        ShouldDrawRemotePlayers = 1
    end

    if BattleScreenData == 1 then
        LocalPlayerIsInBattle = 1
    else
        LocalPlayerIsInBattle = 0
    end
end

-- EVENT-DRIVEN CLIENT CODE --------------------------------------------------------------------------------------------

--- Checks whether the GameCode is one of the ones supported.
--- If it is, it performs initializations and returns `true`.
--- If not, it simply returns `false`
local function IsSupported(GameCode)
    RomCard = emu.memory.cart0
    local Supported = false
    if (GameCode == "AGB-BPRE") or (GameCode == "AGB-ZBDM") then
        local GameVersion = emu:read16(134217916)
        BikeOffset = -3352
        if GameVersion == 26624 then
            mod.GameName = "Pokemon FireRed 1.0"
            mod.GameID = "BPR1"
            MultichoiceAdr = 138282176
        elseif GameVersion == 26369 then
            mod.GameName = "Pokemon FireRed 1.1"
            mod.GameID = "BPR2"
            MultichoiceAdr = 138282288
        else
            mod.GameName = "Pokemon FireRed (Unknown Version)"
            mod.GameID = "BPR1"
            MultichoiceAdr = 138282176
        end
        Supported = true
    elseif (GameCode == "AGB-BPGE") then
        BikeOffset = -3320
        local GameVersion = emu:read16(134217916)
        if GameVersion == 33024 then
            mod.GameName = "Pokemon LeafGreen 1.0"
            mod.GameID = "BPG1"
            MultichoiceAdr = 138281724
        elseif GameVersion == 32769 then
            mod.GameName = "Pokemon LeafGreen 1.1"
            mod.GameID = "BPG2"
            MultichoiceAdr = 138281836
        else
            mod.GameName = "Pokemon LeafGreen (Unknown Version)"
            mod.GameID = "BPG1"
            MultichoiceAdr = 138281724
        end
        Supported = true
    elseif (GameCode == "AGB-BPEE") then
        mod.GameName = "Pokemon Emerald (Not Supported)"
        mod.GameID = "BPEE"
    elseif (GameCode == "AGB-AXVE") then
        mod.GameName = "Pokemon Ruby (Not Supported)"
        mod.GameID = "AXVE"
    elseif (GameCode == "AGB-AXPE") then
        mod.GameName = "Pokemon Sapphire (Not Supported)"
        mod.GameID = "AXPE"
    end

    if Supported then
        CreateRenderers()
        return true
    else
        return false
    end
end

--- Formats a payload to be received and parsed by other players.
local function GetStatePayload()
    -- I'd rather this be on one line, but doing it this way
    -- makes it a lot easier to troubleshoot when one of these values is nil
    --
    -- These values are padded to a specific length.
    -- In the case of numerics, this is achieved by adding a larger number to them.
    --
    -- Starts with four unused bytes (might need to be numeric to preserve compatibility)
    -- Three unused bytes in the middle
    -- One unused byte at the end
    local Payload = "1000"
    Payload = Payload .. (LocalPlayerCurrentX + 2000)
    Payload = Payload .. (LocalPlayerCurrentY + 2000)
    Payload = Payload .. "000"
    Payload = Payload .. (LocalPlayerExtra1 + 100)
    Payload = Payload .. LocalPlayerGender
    Payload = Payload .. LocalPlayerMovementMethod
    Payload = Payload .. LocalPlayerIsInBattle
    Payload = Payload .. (LocalPlayerMapID + 100000)
    Payload = Payload .. (LocalPlayerMapIDPrev + 100000)
    Payload = Payload .. LocalPlayerMapEntranceType
    Payload = Payload .. (LocalPlayerStartX + 2000)
    Payload = Payload .. (LocalPlayerStartY + 2000)
    Payload = Payload .. "0"
    return PACKET_PLAYER_UPDATE, Payload
end

--- Called when a packet is received that is specific to the gameplay
local function OnDataReceived(sender, messageType, payload)
    if messageType == PACKET_RAW_LINK_DATA then
        local data = tonumber(string.sub(payload, 1, 10))
        if data ~= 0 then
            _ReceiveMultiplayerPackets(data - 1000000000)
        end
    elseif messageType == PACKET_RAW_POKEMON_DATA then
        local PokeTemp2 = string.sub(payload, 1, 25)
        _SetPokemonData(PokeTemp2)
    elseif messageType == PACKET_RAW_TRADE_DATA then
        for i = 1, 3 do
            EnemyTradeVars[i] = tonumber(string.sub(payload, i, i))
        end
        EnemyTradeVars[5] = string.sub(payload, 4, 43)

    elseif messageType == PACKET_RAW_BATTLE_DATA then
        for i = 1, 10 do
            EnemyBattleVars[i] = tonumber(string.sub(payload, i, i))
        end
    else
        if messageType == PACKET_REQUEST_POKEMON then
            _GetPokemonTeam()
            _SendRawPokemonData()
        elseif messageType == PACKET_REQUEST_BATTLE then
            --If player requests for a battle
            if (_IsBusy() or LockFromScript ~= 0) then
                _SendToPlayer(PACKET_TOO_BUSY)
            else
                OtherPlayerHasCancelled = 0
                LockFromScript = 10
                TargetPlayer = sender
                _Loadscript(10)
            end
        elseif messageType == PACKET_REQUEST_TRADE then
            --If player requests for a trade
            if (_IsBusy() or LockFromScript ~= 0) then
                _SendToPlayer(PACKET_TOO_BUSY)
            else
                OtherPlayerHasCancelled = 0
                LockFromScript = 11
                TargetPlayer = sender
                _Loadscript(6)
            end
        elseif messageType == PACKET_CANCEL_BATTLE and sender == TargetPlayer then
            --If player cancels battle
            OtherPlayerHasCancelled = 1
        elseif messageType == PACKET_CANCEL_TRADE and sender == TargetPlayer then
            --If player cancels trade
            OtherPlayerHasCancelled = 2
        elseif messageType == PACKET_TOO_BUSY and sender == TargetPlayer and LockFromScript == 4 then
            --If player is too busy to battle
            if Var8000[2] ~= 0 then
                LockFromScript = 7
                _Loadscript(20)
            else
                TextSpeedWait = 5
            end
        elseif messageType == PACKET_TOO_BUSY and sender == TargetPlayer and LockFromScript == 5 then
            --If player is too busy to trade
            if Var8000[2] ~= 0 then
                LockFromScript = 7
                _Loadscript(21)
            else
                TextSpeedWait = 6
            end
        elseif messageType == PACKET_ACCEPT_BATTLE and sender == TargetPlayer and LockFromScript == 4 then
            --If player accepts your battle request
            _RequestRawPokemonData()
            if Var8000[2] ~= 0 then
                LockFromScript = 8
                _Loadscript(13)
            else
                TextSpeedWait = 1
            end
        elseif messageType == PACKET_ACCEPT_TRADE and sender == TargetPlayer and LockFromScript == 5 then
            --If player accepts your trade request
            _RequestRawPokemonData()
            if Var8000[2] ~= 0 then
                LockFromScript = 9
            else
                TextSpeedWait = 2
            end
        elseif messageType == PACKET_DECLINE_BATTLE and sender == TargetPlayer and LockFromScript == 4 then
            --If player denies your battle request
            if Var8000[2] ~= 0 then
                LockFromScript = 7
                _Loadscript(11)
            else
                TextSpeedWait = 3
            end
        elseif messageType == PACKET_DECLINE_TRADE and sender == TargetPlayer and LockFromScript == 5 then
            --If player denies your trade request
            if Var8000[2] ~= 0 then
                LockFromScript = 7
                _Loadscript(7)
            else
                TextSpeedWait = 4
            end
        elseif messageType == PACKET_REFUSE_TRADE_OFFER and sender == TargetPlayer and LockFromScript == 9 then
            --If player refuses trade offer
            OtherPlayerHasCancelled = 3
        elseif messageType == PACKET_PLAYER_UPDATE then
            local player = PlayerProxies[sender]
            if player == nil then
                player = NewPlayerProxy()
                PlayerProxies[sender] = player
            end
            _OnRemotePlayerUpdate(player, payload)
        elseif messageType == PACKET_PLAYER_EXIT then
            PlayerProxies[sender] = nil
        else
            console:log("Received unknown packet type \"" .. messageType .. "\". This may indicate that the client is a little outdated.")
        end
    end
end

--- Called when the connection to the server is lost.
local function OnDisconnect()
    ShouldDrawRemotePlayers = 0
    LockFromScript = 0
    for key, _ in pairs(PlayerProxies) do
        PlayerProxies[key] = nil
    end
end

--- Called whenever the user presses keys.
local function OnKeysRead()
    local Keypress = emu:getKeys()
    local TalkingDirX = 0
    local TalkingDirY = 0
    local AddressGet = ""

    --Hide n seek
    if LockFromScript == 1 then
        if Var8000[5] == 2 then
            --		console:log("Hide n' Seek selected")
            LockFromScript = 0
            _Loadscript(3)
            Keypressholding = 1
            Keypress = 1

        elseif Var8000[5] == 1 then
            --		console:log("Hide n' Seek not selected")
            LockFromScript = 0
            _Loadscript(3)
            Keypressholding = 1
            Keypress = 1
        end
        --Interaction Multi-choice
    elseif LockFromScript == 2 then
        if Var8000[1] ~= Var8000[14] then
            if Var8000[1] == 1 then
                --			console:log("Battle selected")
                FixAddress()
                --			LockFromScript = 4
                --			Loadscript(4)
                LockFromScript = 7
                _Loadscript(3)
                Keypressholding = 1
                Keypress = 1
                --			SendToPlayer(PACKET_REQUEST_BATTLE)

            elseif Var8000[1] == 2 then
                --			console:log("Trade selected")
                FixAddress()
                LockFromScript = 5
                _Loadscript(4)
                Keypressholding = 1
                Keypress = 1
                _SendToPlayer(PACKET_REQUEST_TRADE)

            elseif Var8000[1] == 3 then
                --			console:log("Card selected")
                FixAddress()
                LockFromScript = 6
                _Loadscript(3)
                Keypressholding = 1
                Keypress = 1

            elseif Var8000[1] ~= 0 then
                --			console:log("Exit selected")
                FixAddress()
                LockFromScript = 0
                Keypressholding = 1
                Keypress = 1
            end
        end
    end
    if Keypress ~= 0 then
        if Keypress == 1 or Keypress == 65 or Keypress == 129 or Keypress == 33 or Keypress == 17 then
            --		console:log("Pressed A")

            --SCRIPTS. LOCK AND PREVENT SPAM PRESS.
            if LockFromScript == 0 and Keypressholding == 0 and not _IsBusy() then
                --HIDE N SEEK AT DESK IN ROOM
                if MasterClient == "h" and LocalPlayerCurrentDirection == 3 and LocalPlayerCurrentX == -991 and LocalPlayerCurrentY == -991 and LocalPlayerMapID == 260 then
                    --Server config through bedroom drawer
                    --For temp ram to load up script in 145227776 - 08A80000
                    --8004 is the temp var to get yes or no
                    _Loadscript(1)
                    LockFromScript = 1
                end
                --Interact with players
                for nick, player in pairs(PlayerProxies) do
                    TalkingDirX = LocalPlayerCurrentX - player.CurrentX
                    TalkingDirY = LocalPlayerCurrentY - player.CurrentY
                    if LocalPlayerCurrentDirection == 1 and TalkingDirX == 1 and TalkingDirY == 0 then
                        --		console:log("Player Left")

                    elseif LocalPlayerCurrentDirection == 2 and TalkingDirX == -1 and TalkingDirY == 0 then
                        --		console:log("Player Right")
                    elseif LocalPlayerCurrentDirection == 3 and TalkingDirY == 1 and TalkingDirX == 0 then
                        --		console:log("Player Up")
                    elseif LocalPlayerCurrentDirection == 4 and TalkingDirY == -1 and TalkingDirX == 0 then
                        --		console:log("Player Down")
                    end
                    if (LocalPlayerCurrentDirection == 1 and TalkingDirX == 1 and TalkingDirY == 0) or (LocalPlayerCurrentDirection == 2 and TalkingDirX == -1 and TalkingDirY == 0) or (LocalPlayerCurrentDirection == 3 and TalkingDirX == 0 and TalkingDirY == 1) or (LocalPlayerCurrentDirection == 4 and TalkingDirX == 0 and TalkingDirY == -1) then

                        --		console:log("Player Any direction")
                        emu:write16(Var8000Adr[1], 0)
                        emu:write16(Var8000Adr[2], 0)
                        emu:write16(Var8000Adr[14], 0)
                        TargetPlayer = nick
                        LockFromScript = 2
                        _Loadscript(2)
                    end
                end
            end
            Keypressholding = 1
        elseif Keypress == 2 then
            if LockFromScript == 4 and Keypressholding == 0 and Var8000[2] ~= 0 then
                --Cancel battle request
                _Loadscript(15)
                _SendToPlayer(PACKET_CANCEL_BATTLE)
                LockFromScript = 0
            elseif LockFromScript == 5 and Keypressholding == 0 and Var8000[2] ~= 0 then
                --Cancel trade request
                _Loadscript(16)
                _SendToPlayer(PACKET_CANCEL_TRADE)
                LockFromScript = 0
                TradeVars[1] = 0
                TradeVars[2] = 0
                TradeVars[3] = 0
                OtherPlayerHasCancelled = 0
            elseif LockFromScript == 9 and (TradeVars[1] == 2 or TradeVars[1] == 4) and Keypressholding == 0 and Var8000[2] ~= 0 then
                --Cancel trade request
                _Loadscript(16)
                _SendToPlayer(PACKET_CANCEL_TRADE)
                LockFromScript = 0
                TradeVars[1] = 0
                TradeVars[2] = 0
                TradeVars[3] = 0
                OtherPlayerHasCancelled = 0
            end
            Keypressholding = 1
        elseif Keypress == 4 then
            --		GetPokemonTeam()
            --		SetEnemyPokemonTeam()
            --		console:log("Pressed Select")
        elseif Keypress == 8 then
            --		console:log("Pressed Start")
        elseif Keypress == 16 then
            --		console:log("Pressed Right")
        elseif Keypress == 32 then
            --		console:log("Pressed Left")
        elseif Keypress == 64 then
            --		console:log("Pressed Up")
        elseif Keypress == 128 then
            --		console:log("Pressed Down")
        elseif Keypress == 256 then
            --		console:log("Pressed R-Trigger")
            --	if LockFromScript == 0 and Keypressholding == 0 then
            --	console:log("Pressed R-Trigger")
            --	ApplyMovement(0)
            --		emu:write16(Var8001Adr, 0)
            --	BufferString = Player2ID
            --		Loadscript(12)
            --		LockFromScript = 5
            --		local TestString = ReadBuffers(33692880, 4)
            --		WriteBuffers(33692912, TestString, 4)
            --	console:log("String: " .. TestString)

            --		RequestPokemonData()
            --		if EnemyPokemon[6] ~= 0 then
            --			SetEnemyPokemonTeam(0,1)
            --		end

            --	LockFromScript = 8
            --		SendMultiplayerPackets(0,256)
            --	end
            --	Keypressholding = 1
        elseif Keypress == 512 then
            --		console:log("Pressed L-Trigger")
        end
    else
        Keypressholding = 0
    end
end

--- Called on each frame to update the current knowledge of the game's state.
local function UpdateGameState()
    _GetScreenState()
    _GetPosition()
    _GetSpriteData()
    _DoScriptUpdates()
end

--- Returns a nice, readable string representation of the game's state.
--- Displayed in the console below connection information.
local function GetStateForConsole()
    local out = "Nearby Players:"
    for nick, _ in pairs(PlayerProxies) do
        out = out .. nick .. "\n"
    end
    return out
end

--- Called to initiate rendering of remote players and other related things.
local function Render()
    if ShouldDrawRemotePlayers == 1 then
        local currentRendererIndex = 1
        _CalculateCamera()
        -- loop over players, updating their positions and rendering them
        for _, player in pairs(PlayerProxies) do
            -- Update player position based on animation id
            _AnimatePlayerMovement(player)
            -- Check whether the player is within the bounds of the camera
            _UpdatePlayerVisibility(player)
            if player.PlayerVis == 1 then
                -- Draw the sprite data
                _RenderPlayer(player, Renderers[currentRendererIndex])
                player.LastRenderer = currentRendererIndex
                currentRendererIndex = currentRendererIndex + 1
                if currentRendererIndex > MAX_RENDERED_PLAYERS then
                    break
                end
            else
                player.LastRenderer = -1
            end
        end
        -- Clear any renderers that weren't used this frame
        for i = currentRendererIndex, MAX_RENDERED_PLAYERS do
            EraseAllRenderInstructionsIfDirty(Renderers[i])
        end
    else
        -- TODO: this probably doesn't need to be set each frame.
        for i = 1, MAX_RENDERED_PLAYERS do
            Renderers[i].isDirty = true
        end
    end
end


mod.GetStatePayload    = GetStatePayload
mod.GetStateForConsole = GetStateForConsole
mod.IsSupported        = IsSupported
mod.Render             = Render
mod.OnDataReceived     = OnDataReceived
mod.OnDisconnect       = OnDisconnect
mod.OnKeysRead         = OnKeysRead
mod.UpdateGameState    = UpdateGameState
mod.Version            = VERSION_NUMBER
return mod