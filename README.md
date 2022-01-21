velar
-------------
Jinlong Yang

# 动态upstream

## 1 upstream

	upstream nginx.ops.http.cdc {
		server 0.0.0.0:80;
		balancer_by_lua_file lualib/velar/main.lua;
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
			local entry = require 'velar.pkg.entry'
			entry.init()
		}

		init_worker_by_lua_block {
			local entry = require 'velar.pkg.entry'
			entry.initworker()
		}
		....
	}

## 4 lualib路径

	lualib
	└── velar
		├── main.lua
		└── pkg
			├── dynamic.lua
			├── entry.lua
			└── qconf.lua

## 5 qconf zk配置

	set /nginx/ops/http/cdc '{"service_name": "com.ops.http.cdc", "service_default_port": "5000", "service_instances": [{"abclass": "default", "weight": 101, "pubenv": "default", "ip": "10.12.20.189", "hostname": "dx-test00.dx", "idc": "dx"}, {"abclass": "default", "weight": 100, "pubenv": "default", "ip": "10.12.20.41", "hostname": "m6-test10.m6", "idc": "m6"}], "service_route_rule": {"route_rule": {"idc": {"default": "dx", "m6": "m6", "dx": "dx"}}, "route": ["idc"]}, "service_timestamp": 1642646255}'

## 6 测试

	curl -H 'x-idc:dx' http://10.12.26.255:9000/cdc
	curl -H 'x-idc:m6' http://10.12.26.255:9000/cdc
	curl -H 'x-idc:all' http://10.12.26.255:9000/cdc

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

