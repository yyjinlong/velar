local upstream = require 'ngx.upstream'
local balancer = require 'ngx.balancer'
local util = require 'velar.util.util'
local json = require 'cjson'
local store = ngx.shared.store

local function retry_filter(instances)
    if type(ngx.ctx.used_instances) == 'nil' or type(instances) == 'nil' then
        return instances
    end
    ngx.log(ngx.ERR, '---------INFO------ current request context is retrying')
    local new_instances = {}
    for _, item in pairs(instances) do
        local ok = true
        for _, ui in pairs(ngx.ctx.used_instances) do
            if item.ip .. ':' .. tostring(item.port) == ui then
                ok = false
                break
            end
        end
        if ok then
            -- 重试其他实例上
            table.insert(new_instances, item)
        end
    end
    return new_instances
end

local function filter(upstream_name, instances)
    local new_instances = {}
    for _, item in pairs(instances) do
        local key = 'ngx_healthcheck_down_' .. upstream_name .. '_' .. item.ip .. '_' .. item.port
        local data = store:get(key)
        if not data then
            table.insert(new_instances, item)
        end
    end
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' positive check match: ' .. util.dump(new_instances))
    return new_instances
end

-- smooth weighted round robin
local function swrr(instances, prefix)
    -- 填充current_weight字段
    for _, item in pairs(instances) do
        local key = prefix .. '_' .. item.ip
        local current_weight = store:get(key)
        if not current_weight then
            current_weight = 0
        end
        item.current_weight = current_weight
    end
    ngx.log(ngx.DEBUG, 'swrr init instance: ' .. json.encode(instances))

    -- swrr
    local selected_instance = nil   -- 请求到来时, 被选择的实例
    local sum_weight = 0            -- 累加所有服务器的权重
    for _, item in pairs(instances) do
        sum_weight = sum_weight + item.weight
        item.current_weight = item.current_weight + item.weight

        if not selected_instance or item.current_weight > selected_instance.current_weight then
            selected_instance = item
        end

        -- 记录当前服务器的current_weight
        local key = prefix .. '_' .. item.ip
        store:set(key, item.current_weight)
    end

    if selected_instance ~= nil then
        selected_instance.current_weight = selected_instance.current_weight - sum_weight
        local key = prefix .. '_' .. selected_instance.ip
        store:set(key, selected_instance.current_weight)
    else
        ngx.log(ngx.ERR, '------INFO------ upstream: ' .. upstream_name .. ' swrr triger baseline return index==0')
        selected_instance = instances[0]
    end
    return selected_instance
end


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

    -- 重试检测
    if not instances or type(ngx.ctx.used_instances) ~= 'nil' then
        if type(ngx.ctx.used_instances) == 'table' then
            local other_instances = retry_filter(instances)
            if #other_instances ~= 0 then
                instances = other_instances
                ngx.log(ngx.DEBUG, 'after retry filter use instances: ' .. json.encode(other_instances))
            else
                ngx.log(ngx.DEBUG, 'after retry filter use default instances')
            end
        end
    end

    -- 正向监测
    local new_instances = filter(upstream_name, instances)
    if #new_instances == 0 then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name .. ' no instances ok, use default instances!!!!')
    else
        instances = new_instances
    end

    -- retry
    local retry_key = global_retry_prefix .. upstream_name
    local retry_val = store:get(retry_key)
    if not ngx.ctx.used_instances then
        balancer.set_more_tries(tonumber(retry_val))
    end

    -- swrr
    selected_instance = swrr(instances, prefix)
    local ok, err = balancer.set_current_peer(selected_instance.ip, selected_instance.port)
    if not ok then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name .. ' failed to set current peer: ', err)
    end
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' select: ' .. selected_instance.ip .. ':' .. selected_instance.port)

    -- 上下文
    if type(ngx.ctx.used_instances) == 'nil' then
        ngx.ctx.used_instances = {}
    end
    table.insert(ngx.ctx.used_instances, selected_instance.ip .. ':' .. tostring(selected_instance.port))
end

local function except()
    ngx.log(ngx.ERR, debug.traceback())
    ngx.exit(ngx.HTTP_NOT_ACCEPTABLE)
end

xpcall(router, except)
