local json = require 'cjson'

local _M = {}

_M.split = function(str, delimiter)
    if str==nil or str=='' or delimiter==nil then
        return nil
    end

    local result = {}
    for match in (str..delimiter):gmatch('(.-)'..delimiter) do
        table.insert(result, match)
    end
    return result
end


_M.dump = function(obj)
    return json.encode(obj)
end


_M.gcd = function(a, b)
    while b ~= 0 do
        a, b = b, a % b
    end
    return a
end

return _M
