local stream_sock = ngx.socket.tcp
local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local new_timer = ngx.timer.at
local sub = string.sub
local re_find = ngx.re.find
local tonumber = tonumber
local tostring = tostring
local ipairs = ipairs
local ceil = math.ceil
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local pcall = pcall
local upstream = require 'ngx.upstream'
local cjson = require('cjson.safe')
local dict = ngx.shared.store

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function (narr, nrec) return {} end
end

local function warn(...)
    log(WARN, "healthcheck: ", ...)
end

local function errlog(...)
    log(ERR, "healthcheck: ", ...)
end

-- 从共享内存获取实例
local function get_primary_peers(upstream)
    local path = 'ngx_instance_' .. upstream
    local data = dict:get(path)
    if not data then
        errlog("healthcheck can't find all instance , upstream : "..upstream)
        return nil
    end
    local peers = cjson.decode(data)
    if not peers then
        errlog("healthcheck can't find all instance , upstream : "..upstream)
        return nil
    end
    return peers
end

local function gen_peer_key(prefix, u, id)
    return "ngx_healthcheck_" .. prefix.. u .."_".. id
end

-- 将检查的结果写入共享内存
local function set_peer_down_globally(ctx, id, value, num)
    local u = ctx.upstream

    local key = gen_peer_key("down_", u , id)
    if value == true then
        -- 写入失败节点
        local ok, err = dict:get(key)
        if not ok then
            errlog("upstream:", u, "peer ", id, " is turned down after ", num, " failure(s)")
            ok , err = dict:safe_set(key, value)
        end
    else
        -- 写入恢复节点
        local ok, err = dict:get(key)
        if ok then
            errlog("upstream:", u, "peer ", id, " is turned up after ", num, " success(s)")
            ok, err = dict:delete(key)
        end
    end
    if not ok then
        errlog("failed to set peer down state: ", err)
    end
end

-- 节点监测失败
local function peer_fail(ctx, id, peer)
    local u = ctx.upstream

    local key = gen_peer_key("nok_", u, id)
    local fails, err = dict:get(key)
    if not fails then
        if err then
            errlog("failed to get peer nok key: ", err)
            return
        end
        fails = 1

        -- below may have a race condition, but it is fine for our
        -- purpose here.
        local ok, err = dict:safe_set(key, 1)
        if not ok then
            errlog("failed to set peer nok key: ", err)
        end
    else
        fails = fails + 1
        local ok, err = dict:incr(key, 1)
        if not ok then
            errlog("failed to incr peer nok key: ", err)
        end
    end

    if fails == 1 then
        key = gen_peer_key("ok_", u , id)
        local succ, err = dict:get(key)
        if not succ or succ == 0 then
            if err then
                errlog("failed to get peer ok key: ", err)
                return
            end
        else
            local ok, err = dict:safe_set(key, 0)
            if not ok then
                errlog("failed to set peer ok key: ", err)
            end
        end
    end

    if fails >= ctx.fall then
        set_peer_down_globally(ctx , id, true, fails)
    end
end

-- 节点监测成功
local function peer_ok(ctx, id, peer)
    local u = ctx.upstream

    local key = gen_peer_key("ok_", u, id)
    local succ, err = dict:get(key)
    if not succ then
        if err then
            errlog("failed to get peer ok key: ", err)
            return
        end
        succ = 1

        -- below may have a race condition, but it is fine for our
        -- purpose here.
        local ok, err = dict:safe_set(key, 1)
        if not ok then
            errlog("failed to set peer ok key: ", err)
        end
    else
        succ = succ + 1
        local ok, err = dict:incr(key, 1)
        if not ok then
            errlog("failed to incr peer ok key: ", err)
        end
    end

    if succ == 1 then
        key = gen_peer_key("nok_", u, id)
        local fails, err = dict:get(key)
        if not fails or fails == 0 then
            if err then
                errlog("failed to get peer nok key: ", err)
                return
            end
        else
            local ok, err = dict:safe_set(key, 0)
            if not ok then
                errlog("failed to set peer nok key: ", err)
            end
        end
    end

    if succ >= ctx.rise then
        set_peer_down_globally(ctx, id, nil, succ)
    end
end

-- shortcut error function for check_peer()
local function peer_warn(ctx, id, peer, ...)
    warn(...)
    peer_fail(ctx, id, peer)
end

-- 节点探测
local function check_peer(ctx, id, peer)
    local ok, err
    local statuses = ctx.statuses
    local req = ctx.http_req

    local sock, err = stream_sock()
    if not sock then
        errlog("failed to create stream socket: ", err)
        return
    end

    sock:settimeout(ctx.timeout)

    -- 默认4层端口探测
    ok, err = sock:connect(peer.ip, peer.port)
    if not ok then
        return peer_warn(ctx, id, peer, "failed to connect to ", peer.ip,":" ,peer.port, ": ", err)
    end

    local bytes, err = sock:send(req)
    if not bytes then
        return peer_warn(ctx, id, peer,
                          "failed to send request to ", peer.ip,":",peer.port, ": ", err)
    end

    -- 接口探测
    if ctx.check_method == 'api' then
        local status_line, err = sock:receive()
        if not status_line then
            peer_warn(ctx, id, peer, "failed to receive status line from ", peer.ip, ":" ,peer.port, ": ", err)
            if err == "timeout" then
                sock:close()  -- timeout errors do not close the socket.
            end
            return
        end

        if statuses then
            local from, to, err = re_find(status_line,
                                          [[^HTTP/\d+\.\d+\s+(\d+)]],
                                          "joi", nil, 1)
            if not from then
                peer_warn(ctx, id, peer,
                           "bad status line from ", peer.ip,":",peer.port, ": ",
                           status_line)
                sock:close()
                return
            end

            local status = tonumber(sub(status_line, from, to))
            if not statuses[status] then
                peer_warn(ctx, id, peer, "bad status code from ",
                           peer.ip,":",peer.port, ": ", status)
                sock:close()
                return
            end
        end
    end

    peer_ok(ctx, id, peer)
    sock:close()
end

local function check_peer_range(ctx, from, to, peers)
    for i = from, to do
        check_peer(ctx, peers[i].ip.."_"..peers[i].port, peers[i])
    end
end

local function check_peers(ctx, peers)
    local n = #peers
    if n == 0 then
        return
    end

    local concur = ctx.concurrency
    if concur <= 1 then
        for i = 1, n do
            check_peer(ctx, peers[i].ip.."_"..peers[i].port, peers[i])
        end
    else
        local threads
        local nthr

        if n <= concur then
            nthr = n - 1
            threads = new_tab(nthr, 0)
            for i = 1, nthr do
                threads[i] = spawn(check_peer, ctx, peers[i].ip.."_"..peers[i].port, peers[i])
            end
            check_peer(ctx, peers[i].ip.."_"..peers[i].port, peers[n])

        else
            local group_size = ceil(n / concur)
            local nthr = concur - 1
            threads = new_tab(nthr, 0)
            local from = 1
            local to
            for i = 1, nthr do
                to = from + group_size - 1
                threads[i] = spawn(check_peer_range, ctx, from, to, peers)
                from = from + group_size
            end
            check_peer_range(ctx, to+1, n, peers)
        end

        if nthr and nthr > 0 then
            for i = 1, nthr do
                local t = threads[i]
                if t then
                    wait(t)
                end
            end
        end
    end
end

local function get_lock(ctx)
    local key = "ngx_healthcheck_lock_" .. ctx.upstream
    local ok, err = dict:add(key, true, ctx.interval - 0.001)
    if not ok then
        if err == "exists" then
            return nil
        end
        errlog("failed to add key \"", key, "\": ", err)
        return nil
    end
    return true
end

-- 确保upstream中的节点与当前共享内存中的节点一致
local function update_peers(ctx)
    -- 实例列表可能会变动
    local u = ctx.upstream
    local peers = get_primary_peers(u)
    if not peers then
        errlog("failed to get primary peers: " .. u)
        return
    end

    -- 添加新的
    for i=1, #peers do
        local nohave = 1
        for j=1, #ctx.primary_peers do
            if ctx.primary_peers[j].ip == peers[i].ip and ctx.primary_peers[j].port == peers[i].port then
                nohave = 0
                break
            end
        end
        if nohave == 1 then
            table.insert(ctx.primary_peers, {ip = peers[i].ip,port = peers[i].port})
        end
    end

    if #ctx.primary_peers ~= #peers then
        -- 删除旧的
        for i=1, #ctx.primary_peers do
            if i > #ctx.primary_peers then
                break
            end
            local have = 0
            for j=1, #peers do
                if ctx.primary_peers[i].ip == peers[j].ip and ctx.primary_peers[i].port == peers[j].port then
                    have = 1
                    break
                end
            end
            if have == 0 then
                local key = gen_peer_key("down_", u , ctx.primary_peers[i].ip.."_"..ctx.primary_peers[i].port)
                dict:delete(key)

                key = gen_peer_key("nok_", u , ctx.primary_peers[i].ip.."_"..ctx.primary_peers[i].port)
                dict:delete(key)

                key = gen_peer_key("ok_", u , ctx.primary_peers[i].ip.."_"..ctx.primary_peers[i].port)
                dict:delete(key)

                table.remove(ctx.primary_peers, i)
                i = i -1
            end
        end
    end
end

local function do_check(ctx)
    if get_lock(ctx) then
        update_peers(ctx)
        check_peers(ctx, ctx.primary_peers)
    end
end

local function check(upstream_name, data)
    local config = cjson.decode(data)
    if config == nil then
        error('upstream: ' .. upstream_name .. ' get conf data not json!')
    end

    if not config.service_check_enabled then
        return
    end
    if config.service_check_enabled == 'no' then
        return
    end

    -- 默认检查接口
    local http_req = 'GET / HTTP/1.1\r\n\r\n'
    ngx.log(ngx.DEBUG, 'upstream: ' .. upstream_name .. ' enable healthcheck')
    if config.service_check_method == 'api' then
        if not config.service_check_header then
            http_req = 'GET ' .. config.service_check_url .. ' HTTP/1.1\r\n\r\n'
        else
            http_req = 'GET ' .. config.service_check_url .. ' HTTP/1.1\r\nHost: ' .. config.service_check_header .. '\r\n\r\n'
        end
    end

    -- 超时时间
    local timeout = 1000

    -- 校验返回错误码
    local valid_statuses = {200, 201, 302}
    local statuses
    if valid_statuses then
        statuses = new_tab(0, #valid_statuses)
        for _, status in ipairs(valid_statuses) do
            -- print("found good status ", status)
            statuses[status] = true
        end
    end

    -- 获取upstream中的ip
    local ppeers = get_primary_peers(upstream_name)
    if not ppeers then
        return
    end

    -- 并发数
    local concur = 1

    -- 健康探测的时间间隔
    local interval = config.service_check_interval

    -- 对DOWN的设备，连续rise次成功，认定为UP
    local rise = 2

    -- 对UP的设备，连续fall次失败，认定为DOWN
    local fall = config.service_check_window

    local ctx = {
        upstream = upstream_name,
        primary_peers = ppeers,
        http_req = http_req,
        timeout = timeout,
        interval = interval,
        fall = fall,
        rise = rise,
        statuses = statuses,
        concurrency = concur,
        check_method = config.service_check_method,
    }

    local ok, err = pcall(do_check, ctx)
    if not ok then
        errlog("failed to run healthcheck cycle: ", err)
    end
end

local _M = {}

-- 正向检查(仅支持http)
_M.positive_check = function()
    local ok, qconf = pcall(require, 'velar.util.qconf')
    if not ok then
        ngx.log(ngx.ERR, 'import qconf error')
        return
    end

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
            --ngx.log(ngx.ERR, '--check upstream: ' .. upstream_name .. ' get conf: ' .. conf)
            check(upstream_name, conf)
        end
    end

    local ok, err = new_timer(1, _M.positive_check)
    if not ok then
        if err ~= "process exiting" then
            errlog("failed to create timer: ", err)
        end
        return
    end
end

return _M
