local upstream = require 'ngx.upstream'
local qconf = require 'velar.util.qconf'
local util = require 'velar.util.util'
local json = require 'cjson'
local store = ngx.shared.store

-- 全局变量: 共享内存key前缀
global_timestamp_prefix = 'ngx_timestamp_'
global_instance_prefix = 'ngx_instance_'
global_route_prefix = 'ngx_route_'
global_retry_prefixy = 'ngx_retry_'

-- 全局变量: 实现平滑加权轮训
global_upstream_wrr_dict = {}


local function update_route(upstream_name, route_priorities, route_rule, instances)
    --[[
		"route": [
		  "idc"
		],
		"route_rule": {
		  "idc": {
		    "dx": "dx",
		    "m6": "m6",
		    "default": "dx"
		  }
		}
    --]]
	-- 按优先级进行遍历
	for _, route in pairs(route_priorities) do
        ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' cache rule route: ', route)
		-- 遍历该规则
        local rule_map = route_rule[route]
		for tag, val in pairs(rule_map) do
			-- 遍历实例, 匹配规则标签
		    local match_instance = {}
			for i=1, #instances do
                -- pubenv是default情况下, 需要包含小流量机器
                if route == 'pubenv' and tag == 'default' then
                    if instances[i][route] ~= 'sandbox' then
					    table.insert(match_instance, instances[i])
                    end
				elseif instances[i][route] == val then
					table.insert(match_instance, instances[i])
				end
			end

            local key = global_instance_prefix .. upstream_name .. '_' .. route .. '_' .. tag
            local val = json.encode(match_instance)
            store:safe_set(key, val)
			ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update route key: '..key)
			ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update route val: '..val)
		end
    end
end

local function update_one(upstream_name, data)
    local config = json.decode(data)
    if config == nil then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name .. ' qconf get conf not json!')
        return
    end

    -- (1) 根据时间戳判断配置是否更新
    local timestamp_key = global_timestamp_prefix .. upstream_name
    local timestamp = store:get(timestamp_key)
    if timestamp ~= nil and tonumber(timestamp) == config.service_timestamp then
        return
    end
    store:safe_set(timestamp_key, config.service_timestamp)
    ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' config changed')

    -- (2) 存储全量实例信息
    local instances = {}
    for _, item in pairs(config.service_instances) do
        table.insert(instances, item)
    end

    local new_instances = {}
    for _, item in pairs(instances) do
        local ins = {}
        ins['ip'] = item.ip
        ins['idc'] = item.idc
        ins['weight'] = item.weight
        if tonumber(item.port) == nil then
            item.port = config.service_default_port 
        end
        ins['port'] = item.port
        table.insert(new_instances, ins)
    end
    local instance_key = global_instance_prefix .. upstream_name
    local instance_val = json.encode(new_instances)
    store:safe_set(instance_key, instance_val)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update service instance: ', instance_val)

    -- (3) 存储路由信息
    local route_key = global_route_prefix .. upstream_name
    local route_msg = json.encode(config.service_route_rule)
    store:safe_set(route_key, route_msg)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update service route finish')

    -- (4) 连接重试
    local retry_key = global_retry_prefixy .. upstream_name
    store:safe_set(retry_key, tostring(config.service_connect_retry))
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update service retry finish')

	-- (5) 存储路由规则
    local route_config = config.service_route_rule
    local route_priorities = route_config.route
	local route_rule = route_config.route_rule
	update_route(upstream_name, route_priorities, route_rule, instances)
	ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update route rule finish')
end

local _M = {}

function _M:update()
    xpcall(function()
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
                update_one(upstream_name, conf)
            end
        end
    end,
    function()
        ngx.log(ngx.ERR, debug.traceback())
    end)

    local ok, err = ngx.timer.at(1, _M.update)
    if not ok then
        ngx.log(ngx.ERR, 'create timer failed: ', err)
    end
end

function _M:timer()
    --
    -- 定时器: 获取所有upstream配置, 解析路由规则, 将每一组路由对应的实例信息事先写入共享内存
    --
    if ngx.worker.id() == 0 then
        _M.update()
        ngx.log(ngx.INFO, 'create timer success for worker 0 realtime update config')
    end
end

return _M
