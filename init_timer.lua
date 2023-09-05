local upstream = require 'ngx.upstream'
local qconf = require 'velar.util.qconf'
local util = require 'velar.util.util'
local json = require 'cjson'
local store = ngx.shared.store

-- 全局变量: 共享内存key前缀
global_timestamp_prefix = 'ngx_timestamp_'
global_instance_prefix = 'ngx_instance_'
global_route_list_prefix = 'ngx_route_list_'
global_route_rule_prefix = 'ngx_route_rule_'
global_route_abclass_prefix = 'ngx_route_abclass_'
global_retry_prefix = 'ngx_retry_'
global_gcd_prefix = 'ngx_gcd_'

-- 全局变量: 实现平滑加权轮询(worker启动注册全局变量, 不能放在dynamic中, 否则没法起到全局记录)
global_upstream_wrr_dict = {}


--[[
    穷举每种规则, 匹配对应的机器, 之后写到nginx共享内存。
    {
      "service_route_rule": {
        "route": ["idc"],
        "route_rule": {
          "idc": {
            "dx": "dx",
            "m6": "m6",
            "default": "dx"
          }
        }
      },
      "service_instances": [
        {
          ...
          "ip": "10.12.20.189",
          "idc": "dx",
          "pubenv": "default",
          "abclass": "default",
          "weight": 100
        }
      ]
    }
    穷举后的规则如下:
    * nginx.ops.http.cdc_idc_dx                          对应实例
    * nginx.ops.http.cdc_idc_dx_pubenv_1                 对应实例
    * nginx.ops.http.cdc_idc_dx_pubenv_1_abclass_0-10    对应实例
    * nginx.ops.http.cdc_idc_dx_pubenv_1_abclass_11-100  对应实例
    * nginx.ops.http.cdc_idc_dx_pubenv_1_abclass_default 对应实例
    * ....
--]]
local function loop_enumerate_rule(index, route_priorities, route_rule, instances, prefix)
    if index > #route_priorities then
        return
    end

    -- 遍历该路由规则
    local route = route_priorities[index]
    for tag, val in pairs(route_rule[route]) do
        -- 遍历实例, 匹配规则标签
        local match_instances = {}
        for i=1, #instances do
            -- pubenv是default情况下, 需要包含小流量机器
            if route == 'pubenv' and tag == 'default' then
                if instances[i][route] ~= 'sandbox' then
                    table.insert(match_instances, instances[i])
                end
            elseif instances[i][route] == val then
                table.insert(match_instances, instances[i])
            end
        end

        local next_prefix =  prefix .. '_' .. route .. '_' .. tag
        ok, err = store:safe_set(next_prefix, json.encode(match_instances))
        if not ok then
            ngx.log(ngx.ERR, 'safe_set write error: ' .. err)
        end
        ngx.log(ngx.DEBUG, 'enum key: ' .. next_prefix .. ' val: ' .. util.dump(match_instances))

        loop_enumerate_rule(index+1, route_priorities, route_rule, match_instances, next_prefix)
    end
end

local function update_one(upstream_name, data)
    local config = json.decode(data)
    if config == nil then
        ngx.log(ngx.ERR, 'upstream: ' .. upstream_name .. ' qconf get conf not json!')
        return
    end

    -- 根据时间戳判断配置是否更新
    local timestamp_key = global_timestamp_prefix .. upstream_name
    local timestamp = store:get(timestamp_key)
    if timestamp ~= nil and tonumber(timestamp) == config.service_timestamp then
        return
    end
    store:safe_set(timestamp_key, config.service_timestamp)
    ngx.log(ngx.INFO, 'upstream: ' .. upstream_name .. ' config changed')

    -- 存储全量实例信息、最大公约数
    local instances = {}
    local gcd_val = config.service_instances[1].weight
    for _, item in pairs(config.service_instances) do
        if tonumber(item.port) == nil then
            item.port = config.service_default_port
        end
        table.insert(instances, item)
        gcd_val = util.gcd(gcd_val, item.weight)
    end
    local instance_key = global_instance_prefix .. upstream_name
    local instance_val = json.encode(instances)
    store:safe_set(instance_key, instance_val)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update service instance: ', instance_val)

    local gcd_key = global_gcd_prefix .. upstream_name
    store:safe_set(gcd_key, gcd_val)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update instance gcd: ', gcd_val)

    -- 存储路由优先级列表
    local route_config = config.service_route_rule
    local route_priorities = route_config.route
    local route_rule = route_config.route_rule

    local route_list_key = global_route_list_prefix .. upstream_name
    local route_list_msg = json.encode(route_priorities)
    store:safe_set(route_list_key, route_list_msg)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update route list finish')

    -- 存储路由规则
    local route_rule_key = global_route_rule_prefix .. upstream_name
    local route_rule_msg = json.encode(route_rule)
    store:safe_set(route_rule_key, route_rule_msg)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update route rule finish')

    -- 存储abclass规则
    if type(route_rule.abclass) ~= 'nil' then
        local route_abclass_key = global_route_abclass_prefix .. upstream_name
        local route_abclass_msg = json.encode(route_rule.abclass)
        store:safe_set(route_abclass_key, route_abclass_msg)
        ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update route ablcass rule finish')
    end

    -- 连接重试
    local retry_key = global_retry_prefix .. upstream_name
    store:safe_set(retry_key, config.service_connect_retry)
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' update service retry: ' .. config.service_connect_retry)

    -- 枚举每种路由规则并存储
    local prefix = global_instance_prefix .. upstream_name
    local index = 1
    loop_enumerate_rule(index, route_priorities, route_rule, instances, prefix)
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
    function(err)
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
