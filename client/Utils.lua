
--- Trim the whitespace before and after a sting.
--- If the input is nil, this returns nil.
local function Trim(s)
    if s == nil then
        return nil
    end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Adds spaces on the right until the string is the target length.
--- If the string is longer than the target length, it is returned unchanged.
local function Rightpad(s, targetLength)
    if string.len(s) > targetLength then
        return s
    end
    return s .. string.rep(" ", targetLength - string.len(s))
end

local mod = {}
mod.Trim = Trim
mod.Rightpad = Rightpad
return mod
