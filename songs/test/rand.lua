rand = {}

-- rand.float() returns a float x where 0.0 <= x < 1.0
-- rand.float(max) returns a float x where 0.0 <= x < max
-- rand.float(min, max) returns a float x where min <= x < max

rand.state = 1
function rand.float(a, b)
	rand.state = rand.state + 1
	local r = math.abs((math.sin(632459.86 * rand.state) * 1023341.55) % 1)
	if not a then
		return r
	elseif not b then
		return r * a
	else
		return r * (a-b) + b
	end
end

return rand
