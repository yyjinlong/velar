local upstream = require 'ngx.upstream'
local balancer = require 'ngx.balancer'
local util = require 'velar.util.util'
local json = require 'cjson'
local store = ngx.shared.store


local function slow_match(upstream_name, route_priorities, access_info)
    --
    -- 根据路由标签顺序逐层匹配
    -- 数量为1, 停止过滤; 数量为0, 返回上层结果
    -- 标签值不匹配, 则采用default
    -- 最终结果可以是1个或多个
    --
    local prefix = global_instance_prefix .. upstream_name
    local all_instance_val = store:get(prefix)
    local instances = json.decode(all_instance_val)

    local next_instances = {}
    for _, route in pairs(route_priorities) do
        local next_prefix = prefix .. '_' .. route .. '_' .. access_info[route]
        ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' slow match prefix: ' .. next_prefix)

        local instance_msg = store:get(next_prefix)
        if not instance_msg then
            break
        end
        next_instances = json.decode(instance_msg)
        if #next_instances > 0 then
            prefix = next_prefix
            instances = next_instances
        else
            break
        end
    end
    return instances, prefix
end

local function quick_match(upstream_name, route_priorities, access_info)
    -- get access prefix
    local prefix = global_instance_prefix .. upstream_name
    for _, route in pairs(route_priorities) do
        local next_prefix = prefix .. '_' .. route .. '_' .. access_info[route]
        prefix = next_prefix
    end
    ngx.log(ngx.DEBUG, 'upstream: ' .. ' quick match get prefix: ' .. prefix)

    local instance_val = store:get(prefix)
    if instance_val == nil then
        return {}, prefix
    end
    ngx.log(ngx.DEBUG, 'upstream: ' .. ' instance val: ' .. instance_val)
    return json.decode(instance_val), prefix
end

local function router()
    local access_info = {}
    local upstream_name = upstream.current_upstream_name()

    local pubenv = ngx.req.get_headers()['x-pubenv']
    if type(pubenv) == 'nil' then
        pubenv = 'default'
    end
    access_info['pubenv'] = pubenv

    local idc = ngx.req.get_headers()['x-idc']
    if type(idc) == 'nil' then
        idc = 'default'
    end
    access_info['idc'] = idc

    local abclass = 'default'
    local cookie_abclass = ngx.var.cookie_abclass
    if cookie_abclass ~= nil then
        local segments = util.split(cookie_abclass, '_')
        local abclass_val = tonumber(segments[2])

        local route_abclass_key = global_route_abclass_prefix .. upstream_name
        local route_abclass_msg = store:get(route_abclass_key)
        if route_abclass_msg ~= nil then
            local abclass_rule = json.decode(route_abclass_msg)
            for range, val in pairs(abclass_rule) do
                local segments = util.split(range, '-')
                if segments and #segments == 2 then
                    local low = tonumber(segments[1])
                    local high = tonumber(segments[2])
                    if abclass_val >= low and abclass_val <= high then
                        abclass = range
                    end
                end
            end
        end
    end
    access_info['abclass'] = abclass
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' request abclass: ' .. abclass)

    local route_list_key = global_route_list_prefix .. upstream_name
    local route_list_msg = store:get(route_list_key)
    local route_priorities = json.decode(route_list_msg)
    local instances, prefix = quick_match(upstream_name, route_priorities, access_info)
    if #instances == 0 then
        instances, prefix = slow_match(upstream_name, route_priorities, access_info)
    end
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' get match instance: ' .. util.dump(instances))

    -- retry
    local retry_key = global_retry_prefix .. upstream_name
    local retry_val = store:get(retry_key)
    balancer.set_more_tries(tonumber(retry_val))

    local gcd_key = global_gcd_prefix .. upstream_name
    local gcd_val = store:get(gcd_key)

    -- wrr
    local offset = gcd_val -- 最大公约数作为偏移量
    local sum_weight = 0   -- 累加所有服务的权重
    local current_weight = global_upstream_wrr_dict[prefix] -- 当前请求的权重
    if not current_weight then
        current_weight = 0
    end

    for i, item in pairs(instances) do
        sum_weight = sum_weight + item.weight
        if current_weight < sum_weight then
            -- 选中
            local ok, err = balancer.set_current_peer(item.ip, item.port)
            if not ok then
                ngx.log(ngx.ERR, 'upstream failed to set current peer: ', err)
            end
            ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' select instance: ' .. item.ip)

            current_weight = current_weight + offset
            if i == #instances and current_weight == sum_weight then
                current_weight = 0
            end
            global_upstream_wrr_dict[prefix] = current_weight
            return
        end
    end

    -- 兜底(wrr没有匹配上)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' wrr no selected instance!!!!')
    math.randomseed(tostring(os.time()):reverse():sub(1,6))
    local index = math.random(1, 2)
    local random_instance = instances[index]
    local ok, err = balancer.set_current_peer(random_instance.ip, random_instance.port)
    if not ok then
        ngx.log(ngx.ERR, 'upstream failed to set current peer: ', err)
    end
end

local function except()
    ngx.log(ngx.ERR, debug.traceback())
    ngx.exit(ngx.HTTP_NOT_ACCEPTABLE)
end

xpcall(router, except)
