
local rand = load_file("rand.lua")

-- missing thoughts:
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
    
    --e = Entity.new(el)
    --    :set_pos(rand.float(0, 512), rand.float(0, 512))
    --    :set_size(100,100)
end


function on_update(time_ms)
    --e:set_pos(rand.float(0, 512), rand.float(0, 512))
end
