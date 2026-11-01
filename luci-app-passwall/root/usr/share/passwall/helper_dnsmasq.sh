#!/bin/sh

valid_conf_dir() {
	case "$1" in /*) ;; *) return 1 ;; esac
	# Unsupported paths/filters must not silently select an unloaded directory.
	case "$1/" in
		*[!a-zA-Z0-9_./-]*|*/../*|*/./*|*//*) return 1 ;;
	esac
}

get_conf_dir() {
	local pid conf_file candidate conf_dir
	DNSMASQ_CONF_DIR=
	TMP_DNSMASQ_PATH=
	DNSMASQ_SECTION=$(uci -q show 'dhcp.@dnsmasq[0]' | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p')
	case "$DNSMASQ_SECTION" in ""|*[!a-zA-Z0-9_]*) return 1 ;; esac
	for pid in $(pidof dnsmasq); do
		[ -r "/proc/$pid/cmdline" ] || continue
		candidate=$(tr '\000' '\n' < "/proc/$pid/cmdline" | awk '$0 == "-C" { getline; print; exit }')
		case "$candidate" in
			/var/etc/dnsmasq.conf.$DNSMASQ_SECTION|/tmp/etc/dnsmasq.conf.$DNSMASQ_SECTION)
				[ -s "$candidate" ] && conf_file=$candidate && break
				;;
		esac
	done
	[ -n "$conf_file" ] || return 1
	conf_dir=$(sed -n 's/^[[:space:]]*conf-dir[[:space:]]*=[[:space:]]*//p' "$conf_file" | sed 's/[[:space:]]*$//')
	conf_dir=${conf_dir%/}
	valid_conf_dir "$conf_dir" && [ -d "$conf_dir" ] && [ -w "$conf_dir" ] || return 1
	DNSMASQ_CONF_DIR=$conf_dir
	TMP_DNSMASQ_PATH=$conf_dir/$CONFIG
}

stretch() {
	#zhenduiluanshezhiDNSderen
	local dnsmasq_server=$(uci -q get dhcp.@dnsmasq[0].server)
	local dnsmasq_noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv)
	local _flag
	for server in $dnsmasq_server; do
		[ -z "$(echo $server | grep '\/')" ] && _flag=1
	done
	[ -z "$_flag" ] && [ "$dnsmasq_noresolv" = "1" ] && {
		local saved_resolvfile resolvfile_set=0
		saved_resolvfile=$(uci -q get dhcp.@dnsmasq[0].resolvfile) && resolvfile_set=1
		# noresolv was 1; save the resolver only when we actually change it.
		printf '%s\n%s\n' "$resolvfile_set" "$saved_resolvfile" > "$TMP_PATH/dnsmasq_resolvfile" || return 1
		uci -q delete dhcp.@dnsmasq[0].noresolv || return 1
		uci -q set dhcp.@dnsmasq[0].resolvfile="$RESOLVFILE" || return 1
	}
	return 0
}

restore_stretch() {
	local resolvfile_set saved_resolvfile
	[ -f "$TMP_PATH/dnsmasq_resolvfile" ] || return 0
	{
		IFS= read -r resolvfile_set
		IFS= read -r saved_resolvfile
	} < "$TMP_PATH/dnsmasq_resolvfile"
	case "$resolvfile_set" in
		1) uci -q set dhcp.@dnsmasq[0].resolvfile="$saved_resolvfile" || return 1 ;;
		0)
			if uci -q get dhcp.@dnsmasq[0].resolvfile >/dev/null; then
				uci -q delete dhcp.@dnsmasq[0].resolvfile || return 1
			fi
			;;
		*) return 1 ;;
	esac
	uci -q set dhcp.@dnsmasq[0].noresolv=1 || return 1
	uci commit dhcp || return 1
	rm -f "$TMP_PATH/dnsmasq_resolvfile"
}

backup_servers() {
	DNSMASQ_DNS=$(uci -q get dhcp.@dnsmasq[0].server | tr ' ' ',')
	if [ -n "${DNSMASQ_DNS}" ]; then
		uci -q set $CONFIG.@global[0].dnsmasq_servers="${DNSMASQ_DNS}" || return 1
		uci commit $CONFIG || return 1
	fi
	return 0
}

restore_servers() {
	OLD_SERVER=$(uci -q get $CONFIG.@global[0].dnsmasq_servers | tr "," " ")
	[ -n "$OLD_SERVER" ] || return 0
	for server in $OLD_SERVER; do
		uci -q del_list dhcp.@dnsmasq[0].server="$server"
		uci -q add_list dhcp.@dnsmasq[0].server="$server" || return 1
	done
	uci commit dhcp || return 1
	uci -q delete $CONFIG.@global[0].dnsmasq_servers || return 1
	uci commit $CONFIG
}

logic_restart() {
	local no_log server status=0
	eval_set_val $@
	_LOG_FILE=$LOG_FILE
	[ -n "$no_log" ] && LOG_FILE="/dev/null"
	stretch || status=1
	if [ "$status" = 0 ] && [ -f "$TMP_PATH/default_DNS" ]; then
		backup_servers || status=1
		if [ "$status" = 0 ]; then
			for server in $(uci -q get dhcp.@dnsmasq[0].server); do
				case "$server" in
					*/*) ;;
					*) uci -q del_list dhcp.@dnsmasq[0].server="$server" || { status=1; break; } ;;
				esac
			done
		fi
	fi
	[ "$status" = 0 ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || status=1
	restore_stretch || status=1
	restore_servers || status=1
	[ "$status" = 0 ] && echolog "重启 dnsmasq 服务" || echolog "DNS 准备、重启或设置恢复失败。"
	LOG_FILE=${_LOG_FILE}
	return "$status"
}

restart() {
	local no_log status=0
	eval_set_val $@
	_LOG_FILE=$LOG_FILE
	[ -n "$no_log" ] && LOG_FILE="/dev/null"
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || status=1
	[ "$status" = 0 ] && echolog "重启 dnsmasq 服务" || echolog "dnsmasq 重启失败。"
	LOG_FILE=${_LOG_FILE}
	return "$status"
}

del_conf_dir() {
	valid_conf_dir "$1" || return 1
	rm -f "$1/dnsmasq-$CONFIG.conf" || return 1
	rm -rf "$1/$CONFIG"
}

del() {
	local status=0
	restore_stretch || status=1
	restore_servers || status=1
	if [ -f "$TMP_PATH/dnsmasq_conf_dir" ]; then
		del_conf_dir "$(cat "$TMP_PATH/dnsmasq_conf_dir")" || status=1
	fi
	if get_conf_dir; then
		del_conf_dir "$DNSMASQ_CONF_DIR" || status=1
	elif [ ! -f "$TMP_PATH/dnsmasq_conf_dir" ]; then
		echolog "无法确认 dnsmasq 配置目录，仅清理已知的 Passwall 配置。"
		status=1
	fi
	# Remove only Passwall's known legacy files; never remove a shared conf-dir.
	rm -f "/tmp/dnsmasq.d/dnsmasq-$CONFIG.conf" "/etc/dnsmasq.d/dnsmasq-$CONFIG.conf" || status=1
	rm -rf "/tmp/dnsmasq.d/$CONFIG" || status=1
	# The caller removes the directory record only after DNS recovery succeeds.
	return "$status"
}

arg1=$1
shift
case $arg1 in
get_conf_dir)
	get_conf_dir
	;;
restore)
	restore_stretch && restore_servers
	;;
stretch)
	stretch $@
	;;
del)
	del $@
	;;
restart)
	restart $@
	;;
logic_restart)
	logic_restart $@
	;;
*) ;;
esac
