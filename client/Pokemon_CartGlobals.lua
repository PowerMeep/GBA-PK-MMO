--- These are all of the constants that any pokemon game will likely need.


--- Whether the player is using the male or female sprite
Genders = {
    male   = 0,
    female = 1
}

--- The family of animations
--- Used to separate things like sprite size and offsets
AnimationGroups = {
    on_foot = 0,
    on_bike = 1,
    surfing = 2
}

--- Animations within the groups
AnimationIndices = {
    idle      = 0,
    turning   = 1,
    jumping   = 2,
    slow_move = 3,
    fast_move = 4
}

--- Which direction the character is facing
Directions = {
    left  = 1,
    right = 2,
    up    = 3,
    down  = 4
}

--- DX and DY
DeltasByDirection = {
    [Directions.up]    = { 0, -1},
    [Directions.down]  = { 0,  1},
    [Directions.left]  = {-1,  0},
    [Directions.right] = { 1,  0},
}

--- Names for each individual character sprite
PlayerSpriteLabels = {
    foot_idle_left   = 1,
    foot_idle_up     = 2,
    foot_idle_down   = 3,
    walk_left_1      = 4,
    walk_left_2      = 5,
    walk_up_1        = 6,
    walk_up_2        = 7,
    walk_down_1      = 8,
    walk_down_2      = 9,
    bike_idle_left   = 10,
    bike_idle_up     = 11,
    bike_idle_down   = 12,
    bike_left_1      = 13,
    bike_left_2      = 14,
    bike_up_1        = 15,
    bike_up_2        = 16,
    bike_down_1      = 17,
    bike_down_2      = 18,
    run_left_mid     = 19,
    run_left_1       = 20,
    run_left_2       = 21,
    run_up_mid       = 22,
    run_up_1         = 23,
    run_up_2         = 24,
    run_down_mid     = 25,
    run_down_1       = 26,
    run_down_2       = 27,
    surf_sit_down    = 34,
    surf_sit_up      = 35,
    surf_sit_left    = 36
}

SharedSpriteLabels = {
    battle_icon      = 1,
    surf_idle_down_1 = 28,
    surf_idle_up_1   = 29,
    surf_idle_left_1 = 30,
    surf_idle_down_2 = 31,
    surf_idle_up_2   = 32,
    surf_idle_left_2 = 33
}

--- The default sprite for each group and direction
InitialSpritesByGroupAndDirection = {
    [AnimationGroups.on_foot] = {
        [Directions.down]  = PlayerSpriteLabels.foot_idle_down,
        [Directions.up]    = PlayerSpriteLabels.foot_idle_up,
        [Directions.left]  = PlayerSpriteLabels.foot_idle_left,
        [Directions.right] = PlayerSpriteLabels.foot_idle_left
    },
    [AnimationGroups.on_bike] = {
        [Directions.down]  = PlayerSpriteLabels.bike_idle_down,
        [Directions.up]    = PlayerSpriteLabels.bike_idle_up,
        [Directions.left]  = PlayerSpriteLabels.bike_idle_left,
        [Directions.right] = PlayerSpriteLabels.bike_idle_left
    },
    [AnimationGroups.surfing] = {
        [Directions.down]  = PlayerSpriteLabels.surf_sit_down,
        [Directions.up]    = PlayerSpriteLabels.surf_sit_up,
        [Directions.left]  = PlayerSpriteLabels.surf_sit_left,
        [Directions.right] = PlayerSpriteLabels.surf_sit_left
    }
}