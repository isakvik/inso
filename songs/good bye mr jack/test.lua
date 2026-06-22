
local rand = load_file("rand.lua")


function on_init()
    -- render target bloom demo:
    -- capture the hitobjects into "scene", prefilter+blur it through two half-res targets,
    -- then additively composite the glow back over the (still crisp) screen
    --Beatmap.capture_layers("scene", { Layer.BACKGROUND, Layer.HITOBJECTS, Layer.UI })

    Beatmap.capture_layers("scene", { Layer.HITOBJECTS, Layer.CURSOR })

    el_scene = Element.new()
        :set_tex("scene")
        :set_premultiplied(true)
    el_scenecopy = el_scene:clone()
        :set_premultiplied(false)

    target = Drawable.new(el_scene, -9999, 999999, Layer.DEBUG)
        :set_fullscreen(true)
        --:set_pos(-20, 0)

    target2 = target:clone()
        :set_element(el_scenecopy)
        :set_angle(math.pi)
        :set_color(Color.rgba(255,255,255,128))

    schedule_at(30000, function () 
        Beatmap.add_post_pass{ shader = "blur_h",    src = "scene",                dst = "bloom_a", after = Layer.DEBUG }
        Beatmap.add_post_pass{ shader = "blur_v",    src = "bloom_a",              dst = "bloom_b", after = Layer.DEBUG }
        Beatmap.add_post_pass{ shader = "composite", src = { "scene", "bloom_b" }, dst = "screen",  after = Layer.DEBUG }
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
    
    if time_ms > 31000 then
        -- bloom strength: param 0 is read by composite.fs.glsl as BLOOM_STRENGTH (params[0].x)
        Shader.set_param(0, (time_ms/10000 - 3)*math.sin(time_ms*0.0002))
    end
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
