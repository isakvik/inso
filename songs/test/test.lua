
local rand = load_file("rand.lua")

-- missing thoughts (drawable):
-- layer: should be required argument, probably
-- time: should be argument, definitely (with entire map as default)

-- required data:
-- osu_controller
-- on_valid_osu_input
-- check_key
-- on_hitobject_hit
-- get_hitobject_at_ms(1000)

-- animation list
-- storyboards are defined like _M,start,end,x,y,x,y. probably should define animations like that
--  Animation.new()
--      :move(500, 1500, pos, end_pos[, tween])
--      :scale(500, 1500, pos, end_pos)

-- needs specific handling for animation lists... can't just add at any time cuz it's defined as a slice
-- and we do want continuity for performance reasons

function on_init()
    el = Element.new()
        :set_tex("kawayabughorou.jpg")
    
    --d = Drawable.new(el)
    --    :set_pos(rand.float(0, 512), rand.float(0, 512))
    --    :set_size(100,100)
    
    -- todo(isak): hitobjects as relating to the visuals are actually drawables, and it's just temp code
    -- so this kind of stuff won't work (during map runtime). but i gotta make
    -- some indirect game logic hitobject that can be pushed around and tested with, and then render
    -- those. isn't that what the entity is supposed to be, anyway? so i really just need an entity
    -- reference here instead of the hitobject.
    
    -- so this is a logic entity of TYPE hitobject we're referring to. but in reality, we have several
    -- graphical drawables that we all wanna move around; so we need to be able to organize that.
    
    -- ideas for those:
    -- create manipulatable logic entity from hitobject
    --   instance with position and time and diffsettings and such
    --   rendering logic drawables needs parameters so that the logic entity acts as a parent
    
    --hobj = Hitobject.get_at_ms(0) -- needs optional index param so we can get the next at ms 0
    
    list = Hitobject.range_ms(0, 4250)
end


function on_update(time_ms)
    --e:set_pos(rand.float(0, 512), rand.float(0, 512))
    
    for i, hobj in ipairs(list) do 
        x, y = hobj:get_pos()
        x = x + math.cos((time_ms*i) / 1000 + i)* 100
        y = y + math.sin((time_ms*i) / 1000 + i)* 100
        hobj:set_pos(x,y)
    end
    
end
