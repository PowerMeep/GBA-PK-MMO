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


## The Client
The client is composed of a few files.
- Config.lua - This is where you set your name and the server you want to connect to.
- Client.lua - This maintains connection with the server.
- Pokemon.lua - This does all the reading and writing from memory and all the Pokemon-specific logic.
- FireRed_LeafGreen.lua - This stores sprite data and other magic numbers used by the Pokemon script.
- Utils.lua - This stores some basic functions for other scripts to use.

### How to Play
Same as the original.
1. Get [mGBA](https://mgba.io) version 0.10.0 or higher.
2. Put the client scripts in mGBA's `scripts` folder.
3. Edit the `Config.lua` (See [Configuration](#Configuration))
4. Run mGBA.
5. Load the `Client.lua` script.
6. Open your legally ripped ROM file.

### Configuration
Each player will need to edit the Config file and change a few things.

#### Name
The name you want to have when you connect. If you don't set it, you'll get a random one. Maximum 8 characters.

#### Host
The host to connect to. Supports IPv4 and URLs.

#### Port
The port on the host to connect to.

## The Server
This is a dedicated server for the project, written in Python because I'm a lot more
comfortable with that language. It listens for connections and distributes messages between players.

It also attempts to understand the layout of the world and only make each player aware of the others they
might actually be able to _see,_ but there is a caveat to the current approach.
If you're interested, I wrote about it in [the server file.](server/GBA-PK_Server_Dedicated.py)

### Running
1. Edit environment variables (See [Environment Variables](#Environment-Variables))
2. Run the server script somewhere you can reach it with TCP traffic.
3. You can also pull and deploy the image from [DockerHub](https://hub.docker.com/r/powermeep/gba-pk-mmo)

### Environment Variables

#### LOGGING_LEVEL
Just a nice way to set the verbosity of logging.

#### SERVER_NAME
The name of this server as it should appear to players. Max 8 characters.

#### PING_TIME
How long, in seconds, between pings sent to the client.

#### MAX_MISSED_PONGS
How many times a client can not respond to a PING before they are timed out.

#### SUPPORTED_GAMES
A comma-separated list of the game ids that are supported.
It's probably a good idea to keep games with different maps separate from one another.

| GameID | Version        |
|--------|----------------|
| BPR1   |  FireRed v1.0  |
| BPR2   | FireRed v1.1   |
| BPG1   | LeafGreen v1.0 |
| BPG2   | LeafGreen v1.1 |
| AXVE   | Ruby           |
| AXPE   | Sapphire       |
| BPEE   | Emerald        |

#### MAX_PLAYERS
How many players to allow in at a time. I haven't tested how high this can be.
I was able to do decently with 9 in tests, but at some point, there will be issues with
how many players the server can actually respond to at a time.

#### PORT
Sets the port to listen on.


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

I think setting it up this way will make it a lot easier for contributors to add game modules for the games they want to see supported by this.

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
  - Partially fixed by not snapping to new position after only moving one tile.
  - Notes in the animation method in [the client script](client/GBA-PK_Client.lua)
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
