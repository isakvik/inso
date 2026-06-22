local width, height = 0, 0
local dd = nil

function on_init()

    width, height = Window.get_size()
    print("width: " .. width .. "| height: " .. height)
    
    Window.set_opacity(0)
    print("debug text: " .. tostring(Window.debug()))
    posx, posy = Window.get_pos()
    print("posx: " .. posx .. "| posy: " .. posy)
    print("temp: ")

    fake_window = Element.new()
        :set_tex("blue_square.png")
    
    dd = Drawable.new(fake_window, 0, 100000)
        :set_anchor(Anchor.CENTER)
        :set_layer(Layer.OVERLAY)
        :set_pos(0,0)
        :set_size(10, 10)

    a = Animation.new()
        :scale(0, 1, 1,1, 8,8, Tween.CUBIC_OUT)
        :color(0, 1, Color.rgba(255,0,0,255), Color.rgba(0,0,0,0))
        :rotate(0, 1, 0, 999999)
    
    el = Element.new()
        :set_tex("reversearrow.png")
        :set_animation(a)
        :set_shader("wave")
    
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
end

function on_update(time_ms)
    -- dd:set_pos(math.cos(time_ms / 1000) * 100, math.sin(time_ms / 1000) * 100)
    -- for ii, hobj in ipairs(Hitobject.get_visible()) do
    --     i = hobj:get_index()
        
    --     x, y = hobj:get_pos()
    --     x = x + math.cos((time_ms*i*0.001) / 1000 + i*0.1)* i/10
    --     y = y + math.sin((time_ms*i*0.001) / 1000 + i*0.1)* i/10
        
    --     hobj:set_pos(x,y)
    --     --table[i]:set_pos(x,y)

    --     -- hobj:set_cs(math.cos(time_ms*(0.003+i*0.000005))*2 + 3)
    -- end
    
    -- Playfield.set_rotation(math.sin(time_ms / 3000) * 0.1)
    if time_ms > 10000 and time_ms <= 20000 then
        Window.set_opacity(0)
    elseif time_ms > 20000 then
        Window.set_opacity(1)
    end
    tempa, tempb = Window.get_size()

    -- if new_w < width and not(new_w - 1 >= width) then  
    --     Window.set_size(width - 1, height)    
    --     width = width - 1
    -- elseif new_w > width and not(new_w + 1 <= width) then
    --     Window.set_size(width + 1, height)    
    --     width = width + 1
    -- else
    --     new_w = math.random(1, 160) * 10
    -- end
    -- if new_h < height and not(new_h - 1 >= height) then
    --     Window.set_size(width, height - 1)  
    --     height = height - 1
    -- elseif new_h > height and not(new_h + 1 <= height) then
    --     Window.set_size(width, height + 1)  
    --     height = height + 1
    -- else
    --     new_h = math.random(1, 100) * 10
    -- end
    --Playfield.set_rotation(math.sin(time_ms / 3000) * 0.1)
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
--    if judgement == Judgement.MISS then print("ouch") end
--end
--
---- per-note reaction, attach when you build the object (gets self):
----   hobj:register_event("judgement", function(self, judgement, err) ... end)
---- or globally (no self); "judgement" for all, "judgement:Miss" for one type:
----   register_global_event("judgement:Miss", function(judgement, err) ... end)
--
---- run a snippet on the next frame at/after a music time, or after a delay:
----   schedule_at(31200, function() Playfield.set_rotation(0.3) end)
----   schedule_after(250, function() print("quarter second later") end)
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
