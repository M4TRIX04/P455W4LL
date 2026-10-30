module("luci.passwall.util_shadowsocks", package.seeall)
local api = require "luci.passwall.api"
local uci = api.uci
local jsonc = api.jsonc

function gen_config_server(node)
	local config = {}
	config.server_port = tonumber(node.port)
	config.password = node.password
	config.timeout = tonumber(node.timeout)
	config.fast_open = (node.tcp_fast_open and node.tcp_fast_open == "1") and true or false
	config.method = node.method
	config.server = {"[::0]", "0.0.0.0"}

	return config
end

function gen_config(var)
	local node_id = var["-node"]
	if not node_id then
		print("-node 不能为空")
		return
	end
	local node = uci:get_all("passwall", node_id)
	local server_host = var["-server_host"] or node.address
	local server_port = var["-server_port"] or node.port
	local local_addr = var["-local_addr"]
	local local_port = var["-local_port"]
	local mode = var["-mode"]
	local local_socks_address = var["-local_socks_address"] or "0.0.0.0"
	local local_socks_port = var["-local_socks_port"]
	local local_socks_username = var["-local_socks_username"]
	local local_socks_password = var["-local_socks_password"]
	local local_http_address = var["-local_http_address"] or "0.0.0.0"
	local local_http_port = var["-local_http_port"]
	local local_http_username = var["-local_http_username"]
	local local_http_password = var["-local_http_password"]
	local local_tcp_redir_port = var["-local_tcp_redir_port"]
	local local_tcp_redir_address = var["-local_tcp_redir_address"] or "0.0.0.0"
	local local_udp_redir_port = var["-local_udp_redir_port"]
	local local_udp_redir_address = var["-local_udp_redir_address"] or "0.0.0.0"

	if api.is_ipv6(server_host) then
		server_host = api.get_ipv6_only(server_host)
	end
	local server = server_host

	local config = {
		server = server,
		server_port = tonumber(server_port),
		local_address = local_addr,
		local_port = tonumber(local_port),
		password = node.password,
		method = node.method,
		timeout = tonumber(node.timeout),
		fast_open = (node.tcp_fast_open and node.tcp_fast_open == "true") and true or false,
		reuse_port = true,
		tcp_tproxy = var["-tcp_tproxy"] and true or nil
	}

	if node.type == "SS" then
		if node.plugin and node.plugin ~= "none" then
			config.plugin = node.plugin
			config.plugin_opts = node.plugin_opts or nil
		end
		config.mode = mode

	end

	return jsonc.stringify(config, 1)
end

_G.gen_config = gen_config

if arg[1] then
	local func =_G[arg[1]]
	if func then
		print(func(api.get_function_args(arg)))
	end
end