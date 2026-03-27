
local rand = load_file("rand.lua")

-- missing thoughts (drawable):
-- drawable layer: should be required argument, probably

-- expose builtin elements and animations through the api

-- needs easy way to refer to map settings and their consequential results 
--   ar in millis, cs in osupx
--   convert slider to table of positions
--      hobj.slider.get_path_positions(point_sep_length[, offset])

-- diffsettings per object!!
-- custom AR per object is complicated... animation system should be able to handle this

-- map runtime data
-- Beatmap.set_time_rate(1.5)


-- things i shouldn't forget:
-- custom events (observer)
-- trigger_event("spellcard")
-- register_event("spellcard", function () end )
--
-- buffer system (you can declare buffers in the .notosu and just write stuff here)
--
-- event stuff is half-baked - you can trigger events on elements, drawables, hitobjects,
-- and you can schedule them to the future, but you can't pass arguments to them via scheduling
-- (although you can create global state and just use that in the events, but i'd rather avoid that)


function on_init()
    a = Animation.new()
        :color(0, 0.5, Color.rgb(255,0,0), Color.rgb(0,0,255))
        :scale(0, 1, 1,1, 8,8, Tween.CUBIC_OUT)
        :texture(2000, 3000, "nonexisting.jpg") -- throws error, but defaults to white pixel
    
    el = Element.new()
        :set_tex("approachcircle.png")
        :set_animation(a)
        :set_shader("wave")
        
    dd = Drawable.new(el, 0, 0)
        :set_size(100,100)
        :set_anchor(Anchor.CENTER)
        :set_layer(Layer.BACKGROUND)
        :register_event("saft", function (d, beat_n) 
            print("custom event @ beat: " .. beat_n) 
        end)
    
    list = Hitobject.get_in_range_ms(0, 425000)
    
    table = {}
    for i, hobj in ipairs(list) do 
        --hobj:hide()
        t = hobj:get_start_time()
        table[i] = dd:clone()
            :set_pos(hobj:get_pos())
            :set_time(t, t+1200)
    end
    
    register_global_event("hehe", function()
        -- note that this drifts over time, so it's not really a clean repeat every 250ms
        schedule_event("hehe", 250)
        print("hehe loop " .. Beatmap.get_music_time_ms())
    end)
end

function on_update(time_ms)
    for i, hobj in ipairs(list) do 
        x, y = hobj:get_pos()
        x = x + math.cos((time_ms*i*0.001) / 1000 + i*0.1)* i/10
        y = y + math.sin((time_ms*i*0.001) / 1000 + i*0.1)* i/10
        
        hobj:set_pos(x,y)
        table[i]:set_pos(x,y)
    end
    
    Playfield.set_rotation(math.sin(time_ms / 3000) * 0.1)
end

function on_beat(beat)
    -- every 1/1, index 0 meaning the first given timing section (most useful indexing for constructs like beat % 4)
    -- trigger_event("saft", beat)
    
    if beat == 1 then
        trigger_event("hehe", 1)
    end
    
    --if beat % 4 == 0 and s == nil then
    --    s = Sound.play_loop("soft-sliderslide.wav")
    --end
    --
    --if beat % 4 == 2 and s ~= nil then
    --    s:stop()
    --    s = nil
    --end
    
end

--function on_timing_change(beat, bpm)
--    -- every redline
--    print("timing change: " .. beat .. " " .. bpm)
--end
--function on_pause_change(paused)
--    -- boolean
--    if paused then
--        print("paused")
--    else 
--        print("unpaused")
--    end
--end

--function on_judgement(hobj, judgement, timing_error_ms) 
--    print(judgement)
--end
--
--function on_kiai_change(kiai) 
--    print("kiai time: ", kiai)
--end

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
--    --returns mouse in playfield space, can also use get_cursor_pos()
--    print(get_cursor_pos())
--end
