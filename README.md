velar
-------------
Jinlong Yang

# dynamic upstream

## 1 upstream

    upstream nginx.ops.http.cdc {
        server 0.0.0.0:80;
        balancer_by_lua_file lualib/velar/dynamic.lua;
    }

## 2 domain

    server {
        listen 9000;

        location ^~ /cdc {
            proxy_pass http://nginx.ops.http.cdc;
        }
    }

## 3 nginx.conf

    http {
        ....
        lua_shared_dict store 100m;

        init_by_lua_block {
            local init = require 'velar.init_check'
            init.check()
        }

        init_worker_by_lua_block {
            local init = require 'velar.init_timer'
            init.timer()
        }
        ....
    }

## 4 lualib路径

	lualib
	└── velar
		├── dynamic.lua
		├── init_check.lua
		├── init_timer.lua
		└── util
			├── qconf.lua
			└── util.lua

    init_by_lua:
    * nginx启动时, 从qconf读取所有配置, 进行配置检查

    init_worker_by_lua:
    * 启动定时器, 每秒从qconf获取变化的配置, 解析路由规则, 通过排列组合, 穷举每种规则, 匹配得到对应规则的实例信息，使其【事先】写入到nginx共享内存。
    * 这样做的好处: 在定时器中, 已经将名字服务路由规则中的各种匹配规则都写入共享内存, 当upstream被访问的时候, 可直接匹配规则, 从共享内存获取实例. 以达到静态配置upstream时的访问速度, 提升性能。

    balancer_by_lua_file:
    * 获取当前访问的upstream、idc、pubenv、abclass, 从共享内存获取实例信息, 进行路由逐层匹配, 最后经过wrr返回最终的实例


## 5 qconf zk配置

	set /nginx/ops/http/cdc '{"service_name": "com.ops.http.cdc", "service_default_port": "5000", "service_connect_retry": 1, "service_timestamp": 1681819575, "service_route_rule": {"route": ["pubenv", "idc", "abclass"], "route_rule": {"pubenv": {"1": "sandbox", "2": "smallflow", "default": "default"}, "idc": {"dx": "dx", "m6": "m6", "default": "dx"}, "abclass": {"0-10": "seta", "11-100": "setb", "default": "setb"}}}, "service_instances": [{"idc": "dx", "hostname": "dx-ops00.dx", "ip": "10.12.20.189", "port": "", "pubenv": "sandbox", "weight": 1, "abclass": "default"}, {"idc": "m6", "hostname": "dx-ops01.dx", "ip": "10.12.20.41", "port": "", "pubenv": "smallflow", "weight": 1, "abclass": "seta"}, {"idc": "m6", "hostname": "dx-ops02.dx", "ip": "10.12.16.250", "port": "", "pubenv": "default", "weight": 2, "abclass": "setb"}, {"idc": "m6", "hostname": "dx-ops03.dx", "ip": "10.12.25.0", "port": "", "pubenv": "default", "weight": 4, "abclass": "setb"}]}'

## 6 测试

	curl -H 'x-idc:m6' http://10.12.26.255:9000/cdc

	curl -H 'x-idc:m6' -H 'x-pubenv:1' http://10.12.26.255:9000/cdc
	curl -H 'x-idc:m6' -H 'x-pubenv:2' http://10.12.26.255:9000/cdc

	curl -H 'x-idc:m6' --cookie 'abclass=1665295730_09' http://10.12.26.255:9000/cdc
	curl -H 'x-idc:m6' --cookie 'abclass=1665295730_64' http://10.12.26.255:9000/cdc

## 7 测试后端demo

   	# -*- coding:utf-8 -*-

	from flask import Flask
	from werkzeug.serving import run_simple

	app = Flask(__name__)

	@app.route("/cdc")
	def cdc():
		host = '10.12.20.189'
		return "NOTE: cdc host: %s accessed." % host

	if __name__ == '__main__':
		run_simple('0.0.0.0', 5000, app) 

## 8 平滑加权轮训算法

    -- 初始全局变量保存请求
    upstream_wrr_dict = {}

    function swrr()
        for _, item in pairs(instances) do
            local current_weight = upstream_wrr_dict[item.ip]
            if not current_weight then
                current_weight = 0
            end
            -- 填充current_weight字段
            item.current_weight = current_weight
        end

        local index = 0      -- 请求到来选择服务器的索引
        local sum_weight = 0 -- 累加所有服务器的权重
        for i=1, #instances do
            instances[i].current_weight = instances[i].current_weight + instances[i].weight
            sum_weight = sum_weight + instances[i].weight

            if index == 0 or instances[index].current_weight < instances[i].current_weight then
                index = i
            end

            -- 记录当前服务器的current_weight
            local ip = instances[i].ip
            upstream_wrr_dict[ip] = instances[i].current_weight
        end

        local ip = instances[index].ip
        print('当前请求机器: ' .. ip)
        upstream_wrr_dict[ip] = upstream_wrr_dict[ip] - sum_weight
    end

### 8.1 算法原理

    * 每个服务器都有两个权重变量：
        * weight: 配置文件中指定的该服务器的权重, 这个值是固定不变的;
        * current_weight: 服务器目前的权重, 一开始为0, 之后会动态调整;

    * 每次当请求到来, 选取服务器时, 遍历数组中所有服务器.
        * 对于每个服务器, 让它的current_weight增加它的weight;
        * 同时累加所有服务器的weight, 并保存为sum_weight;

    * 遍历完所有服务器之后, 如果该服务器的current_weight是最大的, 就选择这个服务器处理本次请求.
    * 最后把选中的服务器的current_weight减去sum_weight.

