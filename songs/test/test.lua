
local rand = load_file("rand.lua")
local cool = load_file("nonepizza_left_beef.lua")

function on_init()
    el = Element.new()
        :set_tex("kawayabughorou.jpg")
    
    e = Entity.new(el)
        :set_pos(rand.float(0, 512), rand.float(0, 512))
        :set_size(100,100)
end


function on_update(time_ms)
    e:set_pos(rand.float(0, 512), rand.float(0, 512))
end
