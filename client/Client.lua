local Config = require(".Config")
local Utils = require(".Utils")

--- List of all supported games
local SUPPORTED_GAMES = {
    require(".Pokemon")
}

-- CONSTANTS
local PacketTypes = {
    --- Sent by the client when requesting to join a server.
    --- Contains a requested nickname, client version, and loaded gameID.
    JOIN_SERVER = "JOIN",
    --- Sent by the server if the client's `JOIN` was denied.
    --- Contains the reason why in the payload. The socket is closed afterward.
    SERVER_DENY = "DENY",
    --- Sent by the server if the client's `JOIN` was accepted.
    --- Contains an ID for the client to identify itself with.
    SERVER_START = "STRT",
    --- Sent by the client periodically to report its position to the server.
    --- Contains info such as MapID, position, facing, animation, gender, etc.
    --- Everything that is needed by another client to render this one.
    --- Sent by the server to check if a client is still there.
    --- If it is, the client should respond with a `PONG`
    PING         = "PING",
    --- Sent by the client in response to a `PING`.
    PONG         = "PONG",
    --- Sent by the server with the round trip time of the ping-pong.
    PINGPONG     = "PNPN"
}

local DenyReasons = {
    --- The player was denied because the server is at its configured capacity.
    SERVER_FULL      = "FULL",
    --- The player was denied because somebody else in the server is using the same name.
    NAME_TAKEN       = "NAME",
    --- The player was denied because their name had invalid characters in it.
    INVALID_CHARS    = "CHRS",
    --- The player was denied because their `JOIN` packet wasn't understood.
    MALFORMED_PACKET = "MALF"
}

--- Maximum time to wait for a packet from the server before timing out.
local SECONDS_UNTIL_TIMEOUT = 10
--- The number of seconds in between each reconnect attempt
local SECONDS_BETWEEN_RECONNECTS = 10
--- The number of seconds between updating the console
local SECONDS_BETWEEN_CONSOLE_UPDATES = 1

-- SESSION VARIABLES
--- The game that matched this session
local LoadedGame
--- The name of the server we connected to.
local ServerName = "None"

-- Timer variables
-- When Current and Previous are different,
-- then at least one full second has passed.
local PreviousSeconds = 0
local CurrentSeconds = 0
local DeltaTime = 0

--- Copy of the Nickname that has been formatted for sending in packets.
local Nickname = ""

--- The socket used for communications with the server.
local SocketMain = ""
--- The latency between this client and the server.
local Latency = 0

--- A flag for the current connection status
--- - a = not connected
--- - c = connected as client
--- - h = connected as host (not applicable)
local MasterClient = "a"
--- The error the server reported to us when we tried to connect
local ErrorMessage = ""
--- Seconds remaining until the client assumes it has lost connection and enters a reconnect loop.
local TimeoutTimer = 0
--- Seconds remaining until the next reconnect attempt.
local ReconnectTimer = 0
--- Seconds remaining until the next time the console is updated
local ConsoleUpdateTimer = 0

-- CONSOLE UPDATES -----------------------------------------------------------------------------------------------------
local ConsoleForText = console:createBuffer("GBA-PK CLIENT")

--- Sets the given line to display the given text in the console.
local function SetLine(line, text)
    if ConsoleForText ~= nil then
        ConsoleForText:moveCursor(0, line)
        ConsoleForText:print(text)
    end
end

--- Updates the full console with the current client state.
local function UpdateConsole()
    if ConsoleForText == nil then
        return
    end

    ConsoleForText:clear()
    SetLine(0, "Nickname: " .. Nickname)
    SetLine(1, "Connection: " .. Config.Host .. ":" .. Config.Port)
    SetLine(2, "Game: " .. LoadedGame.GameName)

    if MasterClient == "c" then
        SetLine(3, "Server Name: " .. ServerName .. " (" .. Latency .. " ms)")
        SetLine(4, LoadedGame.GetStateForConsole())
    else
        SetLine(3, "Not Connected.")
        if ErrorMessage and string.len(ErrorMessage) > 0 then
            SetLine(4, "Error Message: " .. ErrorMessage)
        end
    end
end

--- Guarantees the nickname will be the correct length.
--- If the nickname is blank, it will be randomly generated.
--- If the nickname is less than the target length, it will be padded with spaces.
--- If the nickname is greater than the target length, it will be truncated.
local function FormatNickname()
    local nickLength = 8
    Nickname = Utils.Trim(Config.Name)
    if Nickname == nil or string.len(Nickname) == 0 then
        console:log("Nickname not set, generating a random one. You can set this in Config.lua")
        local res = ""
        for _ = 1, nickLength do
            res = res .. string.char(math.random(97, 122))
        end
        Nickname = res
    else
        if string.len(Nickname) < nickLength then
            Nickname = Utils.Rightpad(Nickname, nickLength)
        elseif string.len(Nickname) > nickLength then
            Nickname = string.sub(Nickname, 1, nickLength)
        end
    end
end

-- PACKET SENDING ------------------------------------------------------------------------------------------------------
-- The network packets are currently serialized as a 64 character string.
-- While it might be nice to use a more flexible format, like JSON, I think we can still squeeze some more efficiency out
-- of these. Here are some possible iterations.
--
-- V1 (Original)
-- [4 byte GameID][4 byte Nickname][4 byte SenderID][4 byte RecipientID][4 byte PacketType][43 byte Payload][U]
--
-- V2
-- [8 byte SenderID][8 byte RecpientID][4 byte PacketType][43 byte Payload][U]
-- By sending GameID only when joining the game, and by consolidating the nickname and numeric ids into
-- a single field, we can repurpose the first 16 bytes into clean 8 byte sender and recipient IDs. The rest of the packet
-- remains the same, thus most of the parsing code is left alone.
--
-- V3 (Current)
-- [8 byte SenderID][4 byte PacketType][51 byte Payload][U]
-- The vast majority of the packets being sent won't _have_ an intended recipient.
-- The bytes reserved for that would be unused. This approach makes the recipientID part of the payload,
-- so only packets that _need_ a recipient need to define one. The other packets are free to send more data in the payload.
--
-- V4
-- [8 byte SenderID][4 byte PacketType][52 byte Payload]
-- I'm not really sure how often malformed packets show up.
-- If we become confident that we are no longer receiving bad packets, or we have a way to detect / handle them
-- without checking that the 64th character is `U`, then that byte can also be lumped into the payload for a clean 52 bytes.
-- A possible approach would be to verify that the PacketType is recognized. There is a chance for a false positive there,
-- but it's pretty low.

--- Function to format a packet and send it.
--- Global function so it's available to any module that might need it.
function SendData(PacketType, Payload)
    -- If we didn't get a payload at all, initialize to empty string
    if Payload == nil then Payload = "" end

    -- If the payload is less than 43 characters long, add filler
    local PayloadLen = string.len(Payload)
    if PayloadLen < 51 then
        Payload = Payload .. string.rep("0", 51 - PayloadLen)
    end

    -- If the payload is greater than the maximum, block it and report an error
    if PayloadLen > 51 then
        console:log("Error - tried to send a " .. PacketType .. " packet that was too long")
    else
        local Packet = Nickname .. PacketType .. Payload .. "U"
        SocketMain:send(Packet)
    end
end

--- Called by the socket anytime data is available to be consumed.
local function OnDataReceived()
    if LoadedGame == nil then return end

    if not SocketMain:hasdata() then return end

    local ReadData = SocketMain:receive(64)
    if ReadData == nil then return end

    local theLetterU = string.sub(ReadData, 64, 64)
    if theLetterU ~= "U" then return end

    -- If we make it to here, then the packet seems to be valid.
    TimeoutTimer = SECONDS_UNTIL_TIMEOUT

    --- Where this packet originated from.
    local sender      = string.sub(ReadData, 1, 8)
    --- The type of data in the packet.
    local messageType = string.sub(ReadData, 9, 12)
    --- The data that was received
    local payload     = string.sub(ReadData, 13, 63)


    if messageType == PacketTypes.SERVER_START then
        console:log("Joined Successfully!")
        ServerName = sender
        ErrorMessage = ""
        MasterClient = "c"
    elseif messageType == PacketTypes.SERVER_DENY then
        local reason = string.sub(payload, 1, 4)
        if tonumber(reason) ~= nil then
            ErrorMessage = "Server requires client script version " .. reason .. " or higher."
        elseif reason ==  DenyReasons.SERVER_FULL then
            ErrorMessage = "Server is full."
        elseif reason ==  DenyReasons.NAME_TAKEN then
            ErrorMessage = "The name \"" .. Nickname .. "\" is already in use."
        elseif reason ==  DenyReasons.INVALID_CHARS then
            ErrorMessage = "Your nickname contained unsupported characters. Try picking one that only uses letters and numbers."
        elseif reason ==  DenyReasons.MALFORMED_PACKET then
            ErrorMessage = "The server was not able to understand our request."
        else
            ErrorMessage = "Connection refused. Error code: " .. reason
        end
        LoadedGame = nil
        SocketMain:close()
        console:log(ErrorMessage)
    elseif messageType == PacketTypes.PING then
        SendData(PacketTypes.PONG, payload)
    elseif messageType == PacketTypes.PINGPONG then
        Latency = tonumber(string.sub(payload, 1,4))
    else
        LoadedGame.OnDataReceived(sender, messageType, payload)
    end
end

--- Connect to the server, send the `JOIN` packet, and setup the event callback.
local function ConnectToServer()
    console:log("Attempting to connect to server...")
    SocketMain = socket.tcp()
    local success, _ = SocketMain:connect(Config.Host, Config.Port)
    if success then
        console:log("Joining game...")
        SendData(PacketTypes.JOIN_SERVER, LoadedGame.Version .. LoadedGame.GameID .. LoadedGame.GetStatePayload())
        SocketMain:add("received", OnDataReceived)
    else
        console:log("Could not connect to server.")
    end
end

--- Called when the connection to the server times out.
local function OnTimeout()
    console:log("You have timed out")
    ReconnectTimer = SECONDS_BETWEEN_RECONNECTS
    SocketMain:close()
    MasterClient = "a"
    LoadedGame.OnDisconnect()
end

--- Performs any timer-related functions.
local function DoRealTimeUpdates()
    if TimeoutTimer > 0 then
        -- Connected
        TimeoutTimer = TimeoutTimer - DeltaTime
    elseif MasterClient == "c" then
        -- If I was previously connected, I have just timed out.
        OnTimeout()
    elseif ReconnectTimer > 0 then
        -- Waiting to reconnect
        ReconnectTimer = ReconnectTimer - DeltaTime
    else
        -- Connecting
        ReconnectTimer = SECONDS_BETWEEN_RECONNECTS
        ConnectToServer()
    end

    if ConsoleUpdateTimer > 0 then
        ConsoleUpdateTimer = ConsoleUpdateTimer - DeltaTime
    else
        ConsoleUpdateTimer = SECONDS_BETWEEN_CONSOLE_UPDATES
        UpdateConsole()
    end
end


-- CALLBACKS AND SCRIPT START ------------------------------------------------------------------------------------------
--- Called each time a frame is completed.
--- Note that mGBA's framerate may fluctuate by a wide margin (like when fast-forwarding).
local function OnFrameCompleted()
    if LoadedGame == nil then return end

    -- Calculate time difference from previous frame
    CurrentSeconds = os.time()
    DeltaTime = CurrentSeconds - PreviousSeconds
    PreviousSeconds = CurrentSeconds

    -- Update the game state
    LoadedGame.UpdateGameState()

    -- Check timers; send updates to server
    if DeltaTime > 0 then
        DoRealTimeUpdates()
    end

    -- Update visuals
    LoadedGame.Render()
end

--- Called when a game is started or when the script is loaded when the game was already running.
--- Prepares the client code for the main loop.
local function OnGameStart()
    console:log("A new game has started.")
    PreviousSeconds = os.time()
    local GameCode = emu:getGameCode()
    for _, Game in pairs(SUPPORTED_GAMES) do
        if Game.IsSupported(GameCode) then
            LoadedGame = Game
            break
        end
    end
    if LoadedGame == nil then
        console:log("This game is not supported.")
    end
end

--- Called when the game is shut down via the in-game menu.
--- Not sure if it's also called when the application is closed.
local function OnGameShutdown()
    console:log("The game was shut down.")
    SocketMain:close()
    if LoadedGame ~= nil then
        LoadedGame.OnDisconnect()
    end
end

--- Called whenever the user presses a button.
local function OnKeysRead()
    if LoadedGame ~= nil then
        LoadedGame.OnKeysRead()
    end
end

callbacks:add("reset",    OnGameStart)
callbacks:add("shutdown", OnGameShutdown)
callbacks:add("keysRead", OnKeysRead)

FormatNickname()

if not (emu == nil) then
    -- Loaded into mGBA and a game is already running.
    console:log("Script loaded.")
    OnGameStart()

    -- Add this callback after initializing to avoid race conditions.
    callbacks:add("frame", OnFrameCompleted)
else
    -- Either this is mGBA with no running game, or not mGBA at all.
    console:log("Script loaded, but no running game was found. (This is fine)")
    callbacks:add("frame", OnFrameCompleted)
end
