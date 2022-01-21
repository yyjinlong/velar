local upstream = require 'ngx.upstream'
local json = require 'cjson'
local qconf = require 'velar.pkg.qconf'
local store = ngx.shared.store


local _M = {}

function _M:read_config(upstream_name)
    local path, _ = string.gsub(upstream_name, '[.]', '/')
    local err, conf = qconf.get_conf(path)
    if err ~= 0 then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name ..' qconf get conf ' .. path ..' error: ', err)
        return ''
    end
    return conf
end

function _M:check_config(upstream_name, value)
    local config = json.decode(value)
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

function _M:update()
    local upstream_list = upstream.get_upstreams()
    for _, upstream_name in pairs(upstream_list) do
        if string.sub(upstream_name, 1, 6) == 'nginx.' then
            local conf = self:read_config(upstream_name)
            if conf ~= '' then
                self:write_mem(upstream_name, conf)
            end
        end
    end
end

function _M:get_timestamp_key(upstream_name)
    return 'velar_timestamp_' .. upstream_name
end

function _M:get_instance_key(upstream_name)
    return 'velar_instance_' .. upstream_name
end

function _M:get_route_key(upstream_name)
    return 'velar_route_' .. upstream_name
end

function _M:write_mem(upstream_name, value)
    local config = json.decode(value)
    if config == nil then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name .. ' qconf get conf not json!')
        return
    end

    -- NOTE: 根据时间戳判断配置是否更新
    local timestamp_key = self:get_timestamp_key(upstream_name)
    local timestamp = store:get(timestamp_key)
    if timestamp ~= nil and tonumber(timestamp) == config.service_timestamp then
        return
    end
    store:safe_set(timestamp_key, config.service_timestamp)
    ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' config changed')

    local instances = config.service_instances
    if #instances == 0 then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name .. ' no instances config: ' .. value)
        return
    end

    -- NOTE: 存储实例信息
    local all_instance = {}
    local service_port = config.service_default_port
    for _, item in pairs(config.service_instances) do
        table.insert(all_instance, self:route_info(item.ip, service_port, item.weight, item.idc))
    end
    local instance_key = self:get_instance_key(upstream_name)
    local instance_val = json.encode(all_instance)
    store:safe_set(instance_key, instance_val)
    ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' update service instance: ', instance_val)

    -- NOTE: 存储路由信息
    if type(config.service_route_rule) ~= 'table' then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name .. ' service route rule error')
        return
    end
    local route_key = self:get_route_key(upstream_name)
    local route_msg = json.encode(config.service_route_rule)
    store:safe_set(route_key, route_msg)
    ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' update service route: ', route_msg)
end

function _M:route_info(ip, port, weight, idc)
    local route = {}
    route['ip'] = ip
    route['idc'] = idc
    route['port'] = port
    route['weight'] = weight
    return route
end


function _M:filter()
    local upstream_name = upstream.current_upstream_name()
    local instances = self:route_match(upstream_name)
    return self:wrr(upstream_name, instances)
end

-- 名字服务路由规则: 只过滤idc
function _M:route_match(upstream_name)
    local instances = {}

    local instance_key = self:get_instance_key(upstream_name)
    local instance_val = store:get(instance_key)
    local all_instance = json.decode(instance_val)

    local route_key = self:get_route_key(upstream_name)
    local route_msg = store:get(route_key)
    local route_config = json.decode(route_msg)

    local route_rule = route_config.route_rule
    local priorities = route_config.route
    for _, tag in pairs(priorities) do
        local rule = route_rule[tag]
        local idc = ngx.req.get_headers()['x-idc']
        ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' get request header idc: ', idc)
        if idc == nil then
            break
        end

        local rule_tag = rule[idc]
        if rule_tag == nil then
            break
        end
        ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' get request rule tag: ', rule_tag)

        instances = self:match_instance(rule_tag, all_instance)
        if #instances == 0 then
            break
        end
    end

    if #instances == 0 then
        instances = all_instance
    end

    ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' fetch instances: ', json.encode(instances))
    return instances
end

function _M:match_instance(rule_tag, all_instance)
    local instances = {}
    for _, item in pairs(all_instance) do
        if rule_tag == item.idc then
            table.insert(instances, item)
        end
    end
    return instances
end

-- 加权轮训算法: (注: 目前只实现rr)
function _M:wrr(upstream_name, instances)
    if #instances == 1 then
        return instances
    end

    local selected = {}
    local count = #instances
    local last = upstream_wrr_dict[upstream_name]
    if last == nil then
        last = count - 1
    end

    local current = (last + 1) % count
    table.insert(selected, instances[current + 1]) -- 注: lua索引从1开始

    upstream_wrr_dict[upstream_name] = current
    return selected
end

return _M
