
local rand = load_file("rand.lua")

-- missing thoughts (drawable):
-- drawable layer: should be required argument, probably

-- needs easy way to refer to map settings and their consequential results 
--   ar in millis, cs in osupx
--   convert slider to table of positions
--      hobj.slider.get_path_positions(point_sep_length[, offset])

-- todo(isak): should animations be relative? they're not in regular osu, so...
-- they SHOULD be relative cuz animation length as a tweakable parameter would be cool
-- and having them go from 0.0 to 1.0 is intuitive
-- an alternative to this could be animation rate on drawable... is it that good tho?
-- ultimately it's about conventions cuz both ways can get any result

-- diffsettings per object!!
-- custom AR per object is complicated... animation system should be able to handle this

-- custom events (observer)
-- trigger_event("blah")
-- register_event("blah", function () end )

-- map runtime data
-- Map.set_time_rate(1.5)

function on_init()
    a = Animation.new()
        :color(2000, 3000, Color.rgb(255,0,0), Color.rgb(0,0,255))
        :scale(0, 2000, 0,0, 2,2)
        --:texture(2000, 2000, "nonexisting.jpg") -- throws error, but defaults to white pixel
    
    el = Element.new()
        :set_tex("kawayabughorou.jpg")
        :set_animation(a)
        :set_shader("wave")
        
    dd = Drawable.new(el, 0, 0)
        :set_size(100,100)
        :set_anchor(Anchor.CENTER)
        :set_layer(Layer.BACKGROUND)
    
    -- todo(isak) should be able to register custom events through a string here...
    -- using an observer with a set of handles for an event
    -- could be cool
    
    --hobj = Hitobject.get_at_ms(0) -- needs optional index param so we can get the next at ms 0
    
    
    -- todo(isak) this has some off by one bug now...
    list = Hitobject.get_in_range_ms(0, 4250)
    
    table = {}
    for i, hobj in ipairs(list) do 
        hobj:hide()
        t = hobj:get_start_time()
        table[i] = dd:clone()
            :set_pos(hobj:get_pos())
            :set_time(t-1200, t)
    end
end

function _on_update(time_ms)
    for i, hobj in ipairs(list) do 
        x, y = hobj:get_pos()
        x = x + math.cos((time_ms*i*0.01) / 1000 + i*0.1)* 100
        y = y + math.sin((time_ms*i*0.01) / 1000 + i*0.1)* 100
        
        hobj:set_pos(x,y) -- todo(isak) broken on sliders cuz bounding box doesnt move
        table[i]:set_pos(x,y)
    end
end

function _on_beat(beat)
    -- every 1/1, index 1 meaning the first given timing section
    print("beat: " .. beat)
end
function _on_timing_change(beat, bpm)
    -- every redline
    print("timing change: " .. beat .. " " .. bpm)
end
function _on_pause_change(paused)
    -- boolean
    if paused then
        print("paused")
    else 
        print("unpaused")
    end
end

function on_judgement(hobj, judgement, timing_error_ms) 
    print(timing_error_ms)
end


--function on_controller_pressed(key) 
--    --can also use controller_is_down(key)
--    print(key .. " down")
--end
--function on_controller_released(key)
--    --can also use controller_is_up(key)
--    print(key .. " up")
--end
--
--function on_key_pressed(key) 
--    --can also use key_is_down(key)
--    print(key .. " down")
--end
--function on_key_released(key) 
--    --can also use key_is_up(key)
--    print(key .. " up")
--end
--
--function on_cursor_moved(x, y)
--    --returns mouse IN PLAYFIELD SPACE, can also use get_cursor_pos()
--    print(get_cursor_pos())
--end
