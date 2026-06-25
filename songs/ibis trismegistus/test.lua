
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
        :scale(0, 1, 1,1, 8,8, Tween.CUBIC_OUT)
        :color(0, 1, Color.rgba(255,0,0,255), Color.rgba(0,0,0,0))
        :rotate(0, 1, 0, 999999)
    
    el = Element.new()
        :set_tex("reversearrow.png")
        :set_animation(a)
        --:set_shader("wave")
    
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
        
    anim_stillleft = Animation.new()
        :alpha(0, 1, 1, 0)
        :scale(0, 0, 2,2, 2,2)
    anim_stillright = Animation.new()
        :alpha(0, 1, 1, 0)
        :scale(0, 0, 2,2, 2,2)
        :rotate(0, 0, 3.1415, 3.1415)
        
    custom_stillleft = custom_left:clone()
        :set_animation(anim_stillleft)
    custom_stillright = custom_right:clone()
        :set_animation(anim_stillright)
    
    --for i, hobj in ipairs(Hitobject.get_in_range_ms(30000, 60000)) do
    --    hobj:clear_drawables()
    --    hobj:add_element_for_phase(Phase.PREEMPT, custom_left)
    --    hobj:add_element_for_phase(Phase.PREEMPT, custom_right)
    --    hobj:add_element_for_phase(Phase.POSTEMPT, custom_stillleft)
    --    hobj:add_element_for_phase(Phase.POSTEMPT, custom_stillright)
    --    
    --    hobj:add_element_for_phase(Phase.HIT, el)
    --    hobj:set_hit_animation_length(400)
    --    hobj:hide_combo_numbers()
    --end
    --for i, hobj in ipairs(Hitobject.get_in_range_ms(60000, 90000)) do
    --    hobj:clear_drawables()
    --    hobj:add_element_for_phase(Phase.PREEMPT, custom_left)
    --    hobj:add_element_for_phase(Phase.PREEMPT, custom_right)
    --    hobj:add_element_for_phase(Phase.POSTEMPT, custom_stillleft)
    --    hobj:add_element_for_phase(Phase.POSTEMPT, custom_stillright)
    --    
    --    hobj:add_element_for_phase(Phase.HIT, el)
    --    hobj:set_hit_animation_length(900)
    --    hobj:hide_combo_numbers()
    --end

    ely = Element.new()
    
    ball = Element.new():set_tex("reversearrow.png")
    blank = Element.new():set_tex("blank.png")
    
    list = Hitobject.get_in_range_ms(0, 425000)
    
    table = {}
    for i, hobj in ipairs(list) do
        --hobj:hide()
        t = hobj:get_start_time()
    
        --hobj:set_ar(9-i/100)

        hobj:set_slider_element(SliderPart.BALL, ball)

        hobj:set_slider_follow_circle_radius(2.4)
        --hobj:set_slider_element(SliderPart.FOLLOW_CIRCLE, blank)
    end
    
    register_global_event("hehe", function()
        -- note that this drifts over time, it's not a clean repeat every 250ms
        schedule_event("hehe", 250)
        print("hehe loop " .. Beatmap.get_music_time_ms())
    end)

    -- render target bloom demo:
    -- capture the hitobjects into "scene", prefilter+blur it through two half-res targets,
    -- then additively composite the glow back over the (still crisp) screen.
    -- slider bodies composite to the screen on their own, so they bypass the capture.
    --Beatmap.capture_layers("scene", { Layer.HITOBJECTS, Layer.BACKGROUND })
    --Beatmap.add_post_pass{ shader = "blur_h",    src = "scene",                dst = "bloom_a", after = Layer.HITOBJECTS }
    --Beatmap.add_post_pass{ shader = "blur_v",    src = "bloom_a",              dst = "bloom_b", after = Layer.HITOBJECTS }
    --Beatmap.add_post_pass{ shader = "composite", src = { "scene", "bloom_b" }, dst = "screen",  after = Layer.HITOBJECTS }
end

function on_update(time_ms)
    for ii, hobj in ipairs(Hitobject.get_visible()) do
        i = hobj:get_index()
        
        x, y = hobj:get_base_pos()
        x = x + math.cos((time_ms*i*0.001) / 1000 + i*0.1)* i/10
        y = y + math.sin((time_ms*i*0.001) / 1000 + i*0.1)* i/10
        
        hobj:set_pos(x,y)
        --table[i]:set_pos(x,y)

        -- hobj:set_cs(math.cos(time_ms*(0.003+i*0.000005))*2 + 3)
    end
    
    -- rotation anchor demo: pivot the whole playfield about its top-left corner instead of center
    --Playfield.set_rotation_anchor(0, 0)
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
