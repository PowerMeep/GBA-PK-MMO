# GBA PK MMO
This project builds off of @TheHunterManX's work on https://github.com/TheHunterManX/GBA-PK-multiplayer.

As of this commit, it is no longer _compatible_ with the scripts in the original repo.

I'd also like to preface this README as well as the project as a whole with this warning - 
I only reworked the client code. I do not understand the structure of the memory, the game data, what a lot of the numbers are doing,
or how those numbers were found in the first place. Maybe some other people can help with the number hunting?  

The goals I have for this are:
- Dedicated server, so that anybody can come and go as they please.
- Much, _much_ higher player limit.

So basically, I want to make it more like an **MMO**. That said, [PokeMMO](https://pokemmo.com/en/)
already exists, and does a pretty good job, so why would anyone want to use this instead?

This may be preferable to you if you:
- want to use the "vanilla" game UI.
- don't like making online accounts.
- want to host your own, private server.
- want to use a **randomizer**.
- hate yourself.


## Project Layout

### Server
This is a dedicated server for the project, written in Python because I'm a lot more
comfortable with that language. It listens for connections and distributes messages between players.

It also attempts to understand the layout of the world and only make each player aware of the others they
might actually be able to _see,_ but there is a caveat to the current approach. See [Maps and Adjacency](#maps-and-adjacency)

### Client
The client is composed of a main file, and another file housing all the sprite data.

Each player will need to edit this file and change a few fields.
- Nickname
- IPAddress
- Port

And if they're feeling especially brave, feel free to also mess with `MaxRenderedPlayers`. It controls how many other players
the script will try to draw on your screen at the same time. If there are more, it'll just stop trying after this number, leaving the others invisible.
The original script supported 4, I've done a few tests with 8, and I saw a comment that suggests it might be able to go as high as 32.
Be aware that at some point, writing sprite data into memory may overwrite something else and cause memory corruption, and that's generally undesirable.


## Setup

### Server
1. Set ENVs or whatever
2. Run the server script somewhere you can reach it with TCP traffic.
3. Dockerfile included!


### Client
Same as the original.
1. Get [mGBA](https://mgba.io) version 0.10.0 or higher.
2. Put the client scripts in mGBA's `scripts` folder.
3. Edit the `GBA-PK_Client.lua` to point to where the server is, as well as add your desired nickname (up to 8 characters).
4. Run mGBA.
5. Load the script.
6. Open your legally ripped ROM file.


## Roadmap
### Milestone 1: Dedicated Server for Legacy Client
This iteration is meant to be backwards compatible with the existing script.
- [x] Prototype dedicated server.
- [x] Server relays one `SPOS` packet to all other clients.
  - If client does not specify a recipient, the position will be broadcast by the server automatically.
  - Backwards compatible with original script.
- [x] Server squelches extra `SPOS` packets.
  - The recipient id is scrubbed from the packet and stored.
  - If a duplicate one is received within a given time frame, it is not sent again.
- [x] Dockerfile.
- [x] Prevent one client reconnecting repeatedly from filling up all the slots.
  - If a client stops responding to `GPOS` messages, they are kicked.
- [x] Send messages to single clients, so they stop timing out.
- [x] Server sends `DENY` messages and a reason to the client if it couldn't join.
  - [x] The nickname is already taken.
  - [x] The server is full.
  - [x] Client version is not supported.
  - [x] Client's game is not supported.
  - [x] The initial message was malformed.
  - [x] The initial message timed out.
    - This also means the `GPOS` ping can be removed if the client's own timeout is relaxed.
  - [x] The client's requested nickname has invalid characters


### Milestone 2: Improve Legacy Client
This iteration will break backwards compatibility in favor of efficiency and scalability.
- [x] Client reports `DENY` message to the console and disables the script. 
- [x] Client sends its version to the server in join message.
  - 1001 = original.
- [x] Client actually closes socket on shutdown.
- [x] Client does not assume the server is a player.
- [x] Client only sends `SPOS` once, not once for all possible players.
- [x] `SPOS` updates are delta-compressed client side.
- [x] The server sends an `EXIT` to clients to tell them to stop tracking a player.
- [x] The client removes players that send an `EXIT`
- [x] The server organizes connected players by map.
  - Position updates are only set to the current maps and maps suspected to be visible.
  - When a player changes maps, an `EXIT` is sent to any player who will no longer be able to see this player
    and an `EXIT` is sent _from_ those players to the leaving player.
- [ ] The server can send map ids as a payload to `EXIT`
- [ ] The client stops tracking all players in the maps in the `EXIT` payload.
  - This may be fewer packets than one for each player.
- [x] The client has no concept of "maximum number of players".
  - This means that clients don't loop over players based on a hardcoded number.
    They loop over any players they actually **know** to exist.
  - The loop is purely for rendering and interactions.
  - MaxPlayers represents how many players may be _rendered_ at once.
- [x] Both server and client only use one identifier per client as opposed to two
- [x] Server allows configuring max players via env
- [x] Server log has timestamps
- [ ] Reduce `SPOS` frequency to the minimum it can be.
  - Fewer packets/sec means more players can be handled at once.
  - Duplicate packets can be squelched a given number of times.
  - The whole format might be replaceable with direction changes?

### Milestone 3: Restructured Client
I have a plan for how I want to rebuild the client that I think will make it a lot more reusable, both for GBA Pokemon games and possibly _other_ GBA games.
I haven't come up with a detailed TODO list for this refactoring effort, though. The script is broken into three layers - Generic Client, Pokemon Logic, Magic Numbers.
#### Generic Client
This layer will house all the client stuff - Nickname, IP address, connection to server, pings and pongs - anything that would be true for any networked game.

This could, in theory, be reused for any game.

#### Pokemon Logic
This layer will house all the logic unique to the Pokemon titles - tracking of other player entities and their sprites, their interactions,
grabbing the game state from the cartridge, etc.

#### Magic Numbers
The term "Magic Numbers" here refers to all the memory addresses or binary payloads that allow the logic to interface with the game data.
So far, both FireRed and LeafGreen seem to use the same numbers in most situations, but there are a few differences here and there.
I want to pull all these numbers into separate modules that either expose the numbers with readable names, or even expose entire function calls.
The idea here is that the logic layer will identify which game is loaded, and then load the corresponding module it needs to communicate with that cartridge data.
As of this commit, I've only gotten as far as extracting the FR/LG sprite data.

I think setting it up this way will make it a lot easier for contributers to add game modules for the games they want to see supported by this.

### Miscellaneous / Polish
These are all "nice-to-haves" that I didn't consider to be a priority, and I worked on them when it made sense to.
- [ ] Consolidate local and remote player variables where possible.
  - A "superclass" containing variables shared by both.
  - Remote player "class" extends this with unique variables.
  - This means each field only needs to be commented once.
- [ ] The "flashback" on game load is skipped
- [x] Game ID only needs to be sent by the client on join
  - As the payload to the `JOIN` message
- [ ] Squash each X/Y coordinate pair into a single vector table (?)
  - Can also contain functions to perform math with other vectors
- [x] Fix client chugging **hard** when trying to connect to a server that it can't reach.
  - Is this a timeout thing? What is it?
- [x] Fix overly aggressive client reconnect loop
  - Current timers are frame number modulo some arbitrary other number (faster reconnects in fast-forward)
- [ ] Scrape name from save file
- [x] Allow clients to choose their own nickname
  - Generate only if blank or invalid.
  - Names less than the required length are padded with spaces.
  - Longer names are truncated.
- [x] Remove integer id system
  - ~~The numeric id is almost exclusively used in for loops.~~
  - ~~It is also used for generating addresses for sprites and rendering~~
- [x] Longer nicknames
  - Removing integer ids gives 4 more bytes.
  - Removing game ids gives another 4 bytes.
  - Pokemon's internal maximum name length is 7 characters.
- [x] Precalculate visibility of player proxies
  - Each frame, each player is checked for whether their screenspace coordinates are within the camera's bounds.
  - This can be used to skip all rendering polish for that character, allowing more resources for the characters
    which can actually be seen.
- [ ] Map offset values are calculated when a packet is received or when somebody changes maps.
  - Relative coordinate calculation can be simplified by tracking an offset vector for player proxies.
  - The server can use this to offset `SPOS` packets more reliably than the client's current logic.
  - This requires sending the player's current faced direction.
- [x] Separate sprite generation from lerping
- [ ] Skip lerping on players that are not visible at any point for the duration
  - Might not be feasible.
  - Doing this safely requires a check on both the current and future positions.
  - What about another zone that allows lerping but still skips rendering?
- [x] Separation of players from sprite render addresses (screenspace culling)
  - Rendering seems to be the primary limiting factor on maximum players.
  - Define safe "render" zones and allow players to use them on a FIFO basis
- [x] Precalculate the render addresses
- [x] As many players as resources allow
  - The networking seems straightforward enough
  - Rendering may require more address-hunting
- [ ] Fix Trade Bug
  - Malformed `POKE` packet?
- [ ] Fix players in a neighboring map to the north being drawn one tile too low
- [ ] Smooth the animation on the rendered players
  - See [Animation and Interpolation](#Animation-and-Interpolation)
  - Partially fixed by not snapping to new position after only moving one tile.
- [ ] Implement battles
- [x] Cache addresses on load rather than checking the game version frequently
- [ ] The server is aware of map adjacency and offsets, properly allowing cross-map visibility.
  - This is _kind of_ implemented. Solution needs work.
- [ ] Ability to "Follow" other players, like Runescape (?)
  - Gotta be able to break out of it automatically
- [ ] Ability to "Spectate" battles (?)
- [ ] Use a more readable message format, like json (?)
  - Would also be more flexible; messages could be longer or shorter
- [ ] Replace `GPOS` ping with `PING`/`PONG` with challenge 
- [ ] Hide and seek (?)
  - Seems to be partially implemented already
- [ ] Double battles (??)


## Notes and Ramblings

### Animation and Interpolation
The current implementation seems to iterate an animation frame number, 
and then update the `animation` position by a hardcoded amount on specific frames within the animation.
When the `animation` position is a full tile from zero (>15, <-15), the position is updated by one tile in that direction.

Ultimately, a more general time-based interpolation might be more suitable and handle varying framerates a little better.
We know how much time elapses between packets, so all we need to do is interpolate from one packet's position to the next.

### Maps and Adjacency
The current implementation tracks the current and previous maps for each player,
and renders players that share one of them. This can lead to some wonky results.

For networking efficiency reasons, I'd like to track the room a player is in server-side and only
 send position updates to players in the same room.

**Actually** - Here's an idea for how the current system could be built upon:
When a player crosses a map border, we know:
- the previous coordinate on the previous map
- the current coordinate on the current map
- the map transition type (to determine whether these maps are visible from one another)

This can be used to recognize that a pair of maps are visible from one another as well as their offsets.
**SO WHAT IF** this data is **cached** and an internal map of adjacent areas and offsets is stored?
It could also be stored on the filesystem and reloaded next run.

**WARNING** - The MapEntranceType field is not reliable. It is always set to 0 when walking into a new map,
but it is not always set to 1 when walking through a door. As a workaround, I've implemented a non-walkable map.
If an area is known to be non-walkable, then it won't be marked as walkable. Inversely, if a transition was previously
marked as walkable, presumably erroneously, then a non-walkable transition will remove that.
- Walking to new map. Flag always set to 0.
- Entering a building. Flag set to 1 _after_ the first time.
- Fainting teleports you inside Pokemon Center. Flag not set to 1.
- Using "Fly" - Teleports you outside a Pokemon Center. Flag set to 1.
- Using "Teleport" - ??? Probably inside Pokemon Center?

### Timers
#### Frametime Events
The primary entry point for all client script operations is the `onFrameCompleted` method.
As the name implies, it is called after the emulator has completed one frame.
However, mGBA's framerate will fluctuate wildly during gameplay, such as when the user toggles fast-forward mode.
- Updating the visuals of other players
- Reading the current system memory, which may have changed significantly during this frame.
- Sending packets involving changing maps.

#### Realtime Events
Some events are better suited to running incrementally based on the amount of real-world time that has passed.
- Sending current position updates. Having a fixed period between updates allows for more reliable interpolation
  and can help control the total network client.
- Timeouts. These should also happen in realtime. You don't want to time out faster because you're fast-forwarding, right?

#### Async Events
These events are not on a timer and are instead handled asynchronously whenever they occur.
These are set up as callbacks.
- New game is starting.
- Game is shutting down.
- User input detected.
- Reading packets from the server. These should always be handled as soon as they come in.
- The socket has been disconnected.

### Client-side socket management
The client tracks its connection status through two means. This could be reduced to one.
- The current value of `MasterClient`
  - "a" = not connected
  - "c" = connected as client
  - "h" = connected as host (not applicable to this implementation.)
- The current value of the timeout timer
  - a value greater than 0 indicates that we may still be connected
  - a value of 0 or less indicates that we have timed out

### Packet format
The network packets are currently serialized as a 64 character string. 
While it might be nice to use a more flexible format, like JSON, I think we can still squeeze some more efficiency out
of these. Here are some possible iterations.

#### V1 (Original)
`[4 byte GameID][4 byte Nickname][4 byte SenderID][4 byte RecipientID][4 byte PacketType][43 byte Payload][U]`

#### V2 (Current)
`[8 byte SenderID][8 byte RecpientID][4 byte PacketType][43 byte Payload][U]`

By sending GameID only when joining the game, and by consolidating the nickname and numeric ids into
a single field, we can repurpose the first 16 bytes into clean 8 byte sender and recipient IDs. The rest of the packet
remains the same, thus most of the parsing code is left alone.

#### V3
`[8 byte SenderID][4 byte PacketType][51 byte Payload][U]`

The vast majority of the packets being sent won't _have_ an intended recipient.
The bytes reserved for that would be unused. This approach makes the recipientID part of the payload, 
so only packets that _need_ a recipient need to define one. The other packets are free to send more data in the payload.

#### V4
`[8 byte SenderID][4 byte PacketType][52 byte Payload]`

I'm not really sure how often malformed packets show up.
If we become confident that we are no longer receiving bad packets, or we have a way to detect / handle them
without checking that the 64th character is `U`, then that byte can also be lumped into the payload for a clean 52 bytes.
A possible approach would be to verify that the PacketType is recognized. There is a chance for a false positive there,
but it's pretty low.
