local upstream = require 'ngx.upstream'
local balancer = require 'ngx.balancer'
local util = require 'velar.util.util'
local json = require 'cjson'
local store = ngx.shared.store

-- 加权轮训算法: (注: 目前只实现rr)
local function wrr(upstream_name, instances)
    if #instances == 1 then
        return instances
    end

    local selected = {}
    local count = #instances
    local last = global_upstream_wrr_dict[upstream_name]
    if last == nil then
        last = count - 1
    end

    local current = (last + 1) % count
    ngx.log(ngx.DEBUG, 'round robin get access current: ', current)
    table.insert(selected, instances[current + 1]) -- 注: lua索引从1开始

    global_upstream_wrr_dict[upstream_name] = current
    return selected
end

local function get_instances_by_prev_filter(route, tag, prev_instances)
    local match_instance = {}
    for _, item in pairs(prev_instances) do
        if item[route] == tag then
            table.insert(match_instance, item)
        end
    end
    ngx.log(ngx.DEBUG, 'get instances by prev: '..util.dump(match_instance))
    return match_instance
end

local function get_instances_by_route_tag_cache(upstream_name, route, tag)
	local instance_key = global_instance_prefix .. upstream_name .. '_' .. route .. '_' .. tag
    local instance_val = store:get(instance_key)
    ngx.log(ngx.DEBUG, '-------instance key: ' .. instance_key)
    if instance_val == nil then
        return {}
    end
    ngx.log(ngx.DEBUG, '-------instance val: ' .. instance_val)
    return json.decode(instance_val)
end

local function filter(upstream_name, pubenv, idc, abclass)
	--
	-- 根据路由标签顺序逐层匹配
	-- 数量为1, 停止过滤; 数量为0, 返回上层结果;
    -- 标签值不匹配, 则采用default
	-- 最终结果可以是1个或多个
	--
    local instance_key = global_instance_prefix .. upstream_name
    local instance_val = store:get(instance_key)
    local instances = json.decode(instance_val)

    local route_key = global_route_prefix .. upstream_name
    local route_val = store:get(route_key)
    local route_config = json.decode(route_val)
    local route_priorities = route_config.route
    local route_rule = route_config.route_rule

    local prev_instances = instances
    local next_instances = {}
    for _, route in pairs(route_priorities) do
        if route == 'pubenv' then
            if #next_instances == 0 then
                next_instances = get_instances_by_route_tag_cache(upstream_name, route, pubenv)
            else
                next_instances = get_instances_by_prev_filter(route, pubenv, prev_instances)
            end

        elseif route == 'idc' then
            if #next_instances == 0 then
                next_instances = get_instances_by_route_tag_cache(upstream_name, route, idc)
            else
                next_instances = get_instances_by_prev_filter(route, idc, prev_instances)
            end

        elseif route == 'abclass' then
            local find_ab_prefix = 'default'
            for range, val in pairs(route_rule[route]) do
                local segments = util.split(range, '-')
                if segments and #segments == 2 then
                    local low = tonumber(segments[1])
                    local high = tonumber(segments[2])
                    if type(abclass) == 'number' and abclass >= low and abclass <= high then
                        find_ab_prefix = val
                    end
                end
            end
            ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' find abclass prefix: ' .. find_ab_prefix)
            if #next_instances == 0 then
                next_instances = get_instances_by_route_tag_cache(upstream_name, route, find_ab_prefix)
            else
                next_instances = get_instances_by_prev_filter(route, find_ab_prefix, prev_instances)
            end
        end

        if #next_instances == 1 then
            return next_instances
        elseif #next_instances == 0 then
            return prev_instances
        else
            prev_instances = next_instances
        end
    end
    return next_instances
end

local function router()
	--
	-- 路由规则: pubenv->idc->abclass
	--

	-- pubenv: 1(sandbox) 2(smallflow) default(default)
	local pubenv = ngx.req.get_headers()['x-pubenv']
	if type(pubenv) == 'nil' then
		pubenv = 'default'
	end

	-- idc
	local idc = ngx.req.get_headers()['x-idc']
	if type(idc) == 'nil' then
		idc = 'all'
	end

	-- abclass
    local abclass = 'default'
	local abclass_val = ngx.var.cookie_abclass
	if abclass_val ~= nil then
		local segments = util.split(abclass_val, '_')	
		abclass = tonumber(segments[2])
	end
    ngx.log(ngx.DEBUG, 'request abclass: ' .. abclass)

    local upstream_name = upstream.current_upstream_name()
    local instances = filter(upstream_name, pubenv, idc, abclass)
    local select_instances = wrr(upstream_name, instances)
	ngx.log(ngx.DEBUG, 'select instance: ' .. util.dump(select_instances))

    -- retry
    local retry_key = global_retry_prefixy .. upstream_name
    local retry_val = store:get(retry_key)
    balancer.set_more_tries(tonumber(retry_val))

    for _, item in pairs(select_instances) do
        local ok, err = balancer.set_current_peer(item.ip, item.port)
        if not ok then
            ngx.log(ngx.ERR, 'upstream failed to set current peer: ', err)
        end
    end
end

local function except()
    ngx.log(ngx.ERR, debug.traceback())
    ngx.exit(ngx.HTTP_NOT_ACCEPTABLE)
end

xpcall(router, except)
