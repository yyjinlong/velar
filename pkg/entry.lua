local upstream = require 'ngx.upstream'
local balancer = require 'ngx.balancer'
local json = require 'cjson'
local qconf = require 'velar.pkg.qconf'
local dynamic = require 'velar.pkg.dynamic'

local store = ngx.shared.store
local delay = 1

local function worker()
    dynamic:update()
    local ok, err = ngx.timer.at(delay, worker)
    if not ok then
        ngx.log(ngx.ERR, 'create timer failed: ', err)
    end
end

local _M = {}

function _M:init()
    local upstream_list = upstream.get_upstreams()
    for _, upstream_name in pairs(upstream_list) do
        if string.sub(upstream_name, 1, 6) == 'nginx.' then
            local conf = dynamic:read_config(upstream_name)
            if conf == '' then
                error('start or restart stage , get qconf config error')
            end
            dynamic:check_config(upstream_name, conf)
        end
    end
end

function _M:initworker()
    -- NOTE: 安全的启动定时器, 保证只有一个worker做timer
    if ngx.worker.id() == 0 then
        local ok, err = ngx.timer.at(delay, worker)
        if not ok then
            ngx.log(ngx.ERR, 'create timer failed: ', err)
            return
        end
        ngx.log(ngx.INFO, 'create timer success for worker 0 realtime update config.')
    end

    -- NOTE: 注册一个全局变量, 实现轮训
    upstream_wrr_dict = {}
end

function _M:router()
    local instances = dynamic:filter()
    for _, item in pairs(instances) do
        local ok, err = balancer.set_current_peer(item.ip, item.port)
        if not ok then
            ngx.log(ngx.ERR, 'upstream failed to set current peer: ', err)
        end
    end
end

return _M
