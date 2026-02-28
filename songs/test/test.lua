
local rand = load_file("rand.lua")

-- missing thoughts (drawable):
-- layer: should be required argument, probably


function on_init()
    a = Animation.new()
        :color(2000, 3000, Color.rgb(255,0,0), Color.rgb(0,0,255))
        :scale(0, 2000, 0,0, 2,2)
        :texture(2000, 2000, "no.jpg")
    
    el = Element.new()
        :set_tex("kawayabughorou.jpg")
        :set_animation(a)
        
    dd = Drawable.new(el, 0, 0)
        :set_size(100,100)
        :set_anchor(Anchor.CENTER)
        :set_layer(Layer.OVERLAY)
    
    -- todo(isak) should be able to register custom events through a string here...
    -- using an observer with a set of handles for an event
    
    --hobj = Hitobject.get_at_ms(0) -- needs optional index param so we can get the next at ms 0
    
    list = Hitobject.get_in_range_ms(0, 4250)
    
    
    table = {}
    for i, hobj in ipairs(list) do 
        t = hobj:get_start_time()
        table[i] = dd:clone()
            :set_pos(hobj:get_pos())
            :set_time(t-1200, t)
    end
end


function on_update(time_ms)
    -- todo(isak): should animations be relative? they're not in regular osu, so...
    -- d:set_pos(rand.float(0, 512), rand.float(0, 512))
    
    for i, hobj in ipairs(list) do 
        x, y = hobj:get_pos()
        x = x + math.cos((time_ms*i*0.01) / 1000 + i*0.1)* 100
        y = y + math.sin((time_ms*i*0.01) / 1000 + i*0.1)* 100
        hobj:set_pos(x,y)
        table[i]:set_pos(x,y)
    end
end

function on_beat(beat)
    -- every 1/1, index 0 meaning the first given timing section
    print(beat)
    print("beat: " .. beat)
end
function on_bpm_change(beat)
    -- every redline
    print("bpm change: " .. beat)
end
function on_pause_change(paused)
    -- boolean
    if paused then
        print("paused")
    else 
        print("unpaused")
    end
end

function on_judgement(hobj, judgement, timing_error_ms) 
    print(hobj, judgement, timing_error_ms)
end


function on_controller_pressed(key) 
    print(key .. " down")
    print(controller_is_down(key))
end
function on_controller_released(key) 
    print(key .. " up")
    print(controller_is_up(key))
end

function on_key_pressed(key) 
    print(key .. " down")
    print(key_is_down(key))
end
function on_key_released(key) 
    print(key .. " up")
    print(key_is_up(key))
end

function on_cursor_moved(x, y) 
    print(x, y)
end
