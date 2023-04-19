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
    if type(obj) == 'table' then
        local s = '{ '
        for k,v in pairs(obj) do
            if type(k) ~= 'number' then k = '"'..k..'"' end
            s = s .. '['..k..'] = ' .. _M.dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(obj)
    end
end

return _M
