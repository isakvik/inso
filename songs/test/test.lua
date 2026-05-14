
local rand = load_file("rand.lua")

-- missing thoughts (drawable):
-- drawable layer: should be required argument, probably

-- expose builtin elements and animations through the api

-- convert slider to table of positions
--    hobj.slider.get_path_positions(point_sep_length[, offset])

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
        :color(0, 1, Color.rgb(255,0,0), Color.rgb(0,0,255))
        :scale(0, 1, 1,1, 8,8, Tween.CUBIC_OUT)
        :rotate(0, 1, 0, 999999)
        :texture(2000, 3000, "nonexisting.jpg") -- throws error, but defaults to white pixel
    
    el = Element.new()
        :set_tex("reversearrow.png")
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
        --hobj:hide() -- todo(isak): stopped working because of the deferred spawn system
        t = hobj:get_start_time()
    
        hobj:set_ar(9-i/100)
    end
    
    
    
    anim_left = Animation.new()
        :move(0, 1, -3, 0, 0, 0)
        :scale(0,1, 2,2, 2,2)
    anim_right = Animation.new()
        :move(0, 1, 3, 0, 0, 0)
        :scale(0,1, 2,2, 2,2)
        :rotate(0, 0, 3.1415, 3.1415)
        
    custom_left = Element.new()
        :set_tex("reversearrow.png")
        :set_animation(anim_left)
        :use_combo_color(true)
    custom_right = Element.new()
        :set_tex("reversearrow.png")
        :set_animation(anim_right)
        :use_combo_color(true)
        
    anim_hitleft = Animation.new()
        :alpha(0, 1, 1, 0)
        :scale(0, 0, 2,2, 2,2)
    anim_hitright = Animation.new()
        :alpha(0, 1, 1, 0)
        :scale(0, 0, 2,2, 2,2)
        :rotate(0, 0, 3.1415, 3.1415)
        
    custom_hitleft = custom_left:clone()
        :set_animation(anim_hitleft)
    custom_hitright = custom_right:clone()
        :set_animation(anim_hitright)
    
    for i, hobj in ipairs(Hitobject.get_in_range_ms(0, 30000)) do
        hobj:clear_drawables()
        hobj:add_element_for_phase(Phase.PREEMPT, custom_left)
        hobj:add_element_for_phase(Phase.PREEMPT, custom_right)
        hobj:add_element_for_phase(Phase.POSTEMPT, custom_hitleft)
        hobj:add_element_for_phase(Phase.POSTEMPT, custom_hitright)
        
        hobj:add_element_for_phase(Phase.HIT, el)
        hobj:set_hit_animation_length(400)
        hobj:hide_combo_numbers()
    end 
    
    
    register_global_event("hehe", function()
        -- note that this drifts over time, it's not a clean repeat every 250ms
        schedule_event("hehe", 250)
        print("hehe loop " .. Beatmap.get_music_time_ms())
    end)
end

function on_update(time_ms)
    for ii, hobj in ipairs(Hitobject.get_visible()) do
        i = hobj:get_index()
        
        x, y = hobj:get_pos()
        x = x + math.cos((time_ms*i*0.001) / 1000 + i*0.1)* i/10
        y = y + math.sin((time_ms*i*0.001) / 1000 + i*0.1)* i/10
        
        hobj:set_pos(x,y)
        --table[i]:set_pos(x,y)

        -- hobj:set_cs(math.cos(time_ms*(0.003+i*0.000005))*2 + 3)
    end
    
    Playfield.set_rotation(math.sin(time_ms / 3000) * 0.1)
end

--function on_beat(beat)
--    -- every 1/1, index 0 meaning the first given timing section (most useful indexing for constructs like beat % 4)--    trigger_event("saft", beat)
--    
--    if beat == 1 then
--        trigger_event("hehe", 1)
--    end
--    
--    if beat % 4 == 0 and s == nil then
--        s = Sound.play_loop("soft-sliderslide.wav")
--    end
--    
--    if beat % 4 == 2 and s ~= nil then
--        s:stop()
--        s = nil
--    end
--end

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
