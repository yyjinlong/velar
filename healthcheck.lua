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
local cjson = require('cjson.safe')
local upstream = require 'ngx.upstream'
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

    ok, err = sock:connect(peer.ip, peer.port)
    if not ok then
        return peer_warn(ctx, id, peer, "failed to connect to ", peer.ip,":" ,peer.port, ": ", err)
    end

    local bytes, err = sock:send(req)
    if not bytes then
        return peer_warn(ctx, id, peer,
                          "failed to send request to ", peer.ip,":",peer.port, ": ", err)
    end

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

local check
check = function(premature, ctx)
    if premature then
        return
    end

    local ok, err = pcall(do_check, ctx)
    if not ok then
        errlog("failed to run healthcheck cycle: ", err)
    end

    local ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            errlog("failed to create timer: ", err)
        end
        return
    end
end

local _M = {}

-- 生成检测器
_M.spawn_checker = function(opts)
    local typ = opts.type
    if not typ then
        return nil, "\"type\" option required"
    end

    if typ ~= "http" then
        return nil, "only \"http\" type is supported right now"
    end

    local http_req = opts.http_req
    if not http_req then
        return nil, "\"http_req\" option required"
    end

    local timeout = opts.timeout
    if not timeout then
        timeout = 1000
    end

    local interval = opts.interval
    if not interval then
        interval = 1

    else
        interval = interval / 1000
        if interval < 1 then  -- minimum 1s
            interval = 1
        end
    end

    local valid_statuses = opts.valid_statuses
    local statuses
    if valid_statuses then
        statuses = new_tab(0, #valid_statuses)
        for _, status in ipairs(valid_statuses) do
            -- print("found good status ", status)
            statuses[status] = true
        end
    end

    local concur = opts.concurrency
    if not concur then
        concur = 1
    end

    local fall = opts.fall
    if not fall then
        fall = 5
    end

    local rise = opts.rise
    if not rise then
        rise = 2
    end

    local u = opts.upstream
    if not u then
        return nil, "no upstream specified"
    end

    local ppeers = get_primary_peers(u)
    if not ppeers then
        return nil, "failed to get primary peers "
    end

    local ctx = {
        upstream = u,
        primary_peers = ppeers,
        http_req = http_req,
        timeout = timeout,
        interval = interval,
        fall = fall,
        rise = rise,
        statuses = statuses,
        concurrency = concur,
    }

    local ok, err = new_timer(0, check, ctx)
    if not ok then
        return nil, "failed to create timer: " .. err
    end

    return true
end

-- _M.spawn_checker({
--         upstream = "nginx.http.nova",
--         type = "http",
--         http_req = "GET /status HTTP/1.0\r\n\r\n",
--         interval = 500,  -- 100ms
--         valid_statuses = {200},
--         fall = 2,
--     })

-- 正向检查
_M.positive_check = function()
    local upstream_list = upstream.get_upstreams()
    for _, upstream_name in pairs(upstream_list) do
        if string.sub(upstream_name, 1, 6) == 'nginx.' then
            local http_req = 'GET / HTTP/1.1\r\n\r\n'
            local data = {
                upstream=upstream_name,
                type='http',
                http_req = http_req,
            }
            _M.spawn_checker(data)
        end
    end
end

return _M
