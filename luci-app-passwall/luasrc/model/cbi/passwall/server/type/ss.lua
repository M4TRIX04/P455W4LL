local m, s = ...

local api = require "luci.passwall.api"

if not api.is_finded("ss-server") then
	return
end

local type_name = "SS"

local option_prefix = "ss_"

local function option_name(name)
	return option_prefix .. name
end

local ss_encrypt_method_list = {
	-- 只保留实际会用的算法。删掉的及原因（客户端 10 个，服务端多 3 个 camellia）：
	--   rc4-md5 / salsa20 / chacha20 / chacha20-ietf   非 AEAD，已废弃，有已知弱点
	--   aes-128-ctr / aes-192-ctr / aes-256-ctr        非 AEAD，CTR 模式有已知弱点
	--   bf-cfb                                        Blowfish，老旧
	--   aes-192-gcm                                   192 位极少使用，部分实现不支持
	--   xchacha20-ietf-poly1305                       属 Shadowsocks 2022，本体系不用
	--   camellia-128/192/256-cfb（仅服务端）           日系算法，实际无人使用
	"aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
	"aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305"
}

-- [[ Shadowsocks ]]

s.fields["type"]:value(type_name, translate("Shadowsocks"))

o = s:option(Value, option_name("port"), translate("Listen Port"))
o.datatype = "port"

o = s:option(Value, option_name("password"), translate("Password"))
o.password = true

o = s:option(ListValue, option_name("method"), translate("Encrypt Method"))
for a, t in ipairs(ss_encrypt_method_list) do o:value(t) end

o = s:option(Value, option_name("timeout"), translate("Connection Timeout"))
o.datatype = "uinteger"
o.default = 300

o = s:option(Flag, option_name("tcp_fast_open"), "TCP " .. translate("Fast Open"))
o.default = "0"

o = s:option(Flag, option_name("log"), translate("Log"))
o.default = "1"
o.rmempty = false

api.luci_types(arg[1], m, s, type_name, option_prefix)
