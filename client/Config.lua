--- The URL or IP address to connect to.
local Host = "127.0.0.1"

--- The Port to connect to.
local Port = 4096

--- Screen name. Max 8 characters.
local Nickname = ""

--- Maximum number of remote players that can be drawn at once.
--- This does NOT affect how many people can be in your game at once or even nearby.
--- If there are more players nearby than you can draw, they just won't be drawn.
--- Increase this at your own risk. A number too big could corrupt memory or something.
--- - "4" seems pretty safe.
--- - "8" has worked in a few, non-rigorous tests.
--- - "32" shows up in a comment indicating a theoretical maximum value.
local MaxRenderedPlayers = 8


local mod = {}
mod.Host = Host
mod.Port = Port
mod.Nickname = Nickname
mod.MaxRenderedPlayers = MaxRenderedPlayers
return mod
