local upstream = require 'ngx.upstream'
local qconf = require 'velar.util.qconf'
local json = require 'cjson'


function check_one(upstream_name, data)
    local config = json.decode(data)
    if config == nil then
        error('upstream: ' .. upstream_name .. 'get conf data not json')
    end
    if type(config.service_route_rule) ~= 'table' or type(config.service_instances) ~= 'table' then
        error('upstream: ' .. upstream_name .. 'config error!')
    end
    if #config.service_route_rule.route == 0 then
        error('upstream: ' .. upstream_name .. 'route rule is empty!')
    end
    if #config.service_instances == 0 then
        error('upstream: ' .. upstream_name .. 'no instance!')
    end
end


local _M = {}

function _M:check()
    local upstream_list = upstream.get_upstreams()
    for _, upstream_name in pairs(upstream_list) do
        if string.sub(upstream_name, 1, 6) == 'nginx.' then
            local path, _ = string.gsub(upstream_name, '[.]', '/')
            local conf_key = '/' .. path
            local err, conf = qconf.get_conf(conf_key)
            if err ~= 0 then
                ngx.log(ngx.ERR, 'upstream: ' .. upstream_name ..' qconf get conf ' .. path ..' error: ', err)
                return ''
            end
            check_one(upstream_name, conf)
        end
    end
end

return _M
