
function on_init()
    print("hello from lua.on_init()!")
    
    el = Element.new()
        :set_tex("kawayabughorou.jpg")
    
    e = Entity.new(el)
        :set_pos(rand_float(0, 512), rand_float(0, 512))
        :set_size(100,100)
end


function on_update(time_ms)
    
    if e then
        e:set_pos(rand_float(0, 512), rand_float(0, 512))
    end
    
    --while true do end
end

-- rand_float() returns a float x where 0.0 <= x < 1.0
-- rand_float(max) returns a float x where 0.0 <= x < max
-- rand_float(min, max) returns a float x where min <= x < max
local state = 1
function rand_float(a, b)
	state = state + 1
	local r = math.abs((math.sin(632459.86 * state) * 1023341.55) % 1)
	if not a then
		return r
	elseif not b then
		return r * a
	else
		return r * (a-b) + b
	end
end
