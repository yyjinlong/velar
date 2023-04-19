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

## 5 qconf zk配置

	set /nginx/ops/http/cdc '{"service_name": "com.ops.http.cdc", "service_default_port": "5000", "service_connect_retry": 1, "service_timestamp": 1681819575, "service_route_rule": {"route": ["pubenv", "idc", "abclass"], "route_rule": {"pubenv": {"1": "sandbox", "2": "smallflow", "default": "default"}, "idc": {"dx": "dx", "m6": "m6", "default": "dx"}, "abclass": {"0-10": "seta", "11-100": "setb", "default": "setb"}}}, "service_instances": [{"idc": "dx", "hostname": "dx-ops00.dx", "ip": "10.12.20.189", "port": "", "pubenv": "sandbox", "weight": 101, "abclass": "default"}, {"idc": "m6", "hostname": "dx-ops01.dx", "ip": "10.12.20.41", "port": "", "pubenv": "smallflow", "weight": 100, "abclass": "seta"}, {"idc": "m6", "hostname": "dx-ops02.dx", "ip": "10.12.16.250", "port": "", "pubenv": "default", "weight": 100, "abclass": "setb"}, {"idc": "m6", "hostname": "dx-ops03.dx", "ip": "10.12.25.0", "port": "", "pubenv": "default", "weight": 100, "abclass": "setb"}]}'

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

