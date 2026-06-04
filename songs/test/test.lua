local width, height = 0, 0

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

    width, height = Window.get_size()
    print("width: " .. width .. "| height: " .. height)
    
    Window.set_opacity(0)
    print("debug text: " .. tostring(Window.debug()))
    posx, posy = Window.get_pos()
    print("posx: " .. posx .. "| posy: " .. posy)
    print("temp: ")

end

function on_update(time_ms)
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
