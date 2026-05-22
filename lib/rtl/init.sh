#!/bin/ash

TAG="rtl9303"
CONTROL_FIFO="/tmp/control_rtl9303.fifo"
SPI_SOURCE="/dev/spidev1.0"
SPI_ALIAS="/dev/spidev32765.0"
USR_APP="/lib/rtl/usrApp"
LAN_IFACE="lan"
BRIDGE_IFACE="br-lan"
IFACE_WAIT_SECONDS=30
USRAPP_START_DELAY_SECONDS=2
SWITCH_CPU_PORT=27
SWITCH_LAN_PORTS="8 20 24 25 27"

log_msg() {
	logger -t "$TAG" "$*"
}

link_library() {
	local pattern="$1"
	local link_path="$2"
	local source=""
	local candidate

	for candidate in $pattern; do
		[ -e "$candidate" ] || continue
		source="$candidate"
		break
	done

	if [ -z "$source" ]; then
		log_msg "ERROR: missing library for $link_path from $pattern"
		return 1
	fi

	ln -sf "$source" "$link_path"
	log_msg "linked $link_path -> $source"
}

prepare_libraries() {
	link_library "/lib/libubus.so.*" "/lib/libubus.so" || return 1
	link_library "/lib/libubox.so.*" "/lib/libubox.so" || return 1
}

is_valid_mac() {
	echo "$1" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
}

get_iface_mac() {
	local iface="$1"
	local mac_path="/sys/class/net/$iface/address"

	[ -r "$mac_path" ] || return 1
	cat "$mac_path"
}

wait_for_iface() {
	local iface="$1"
	local elapsed=0

	while [ "$elapsed" -lt "$IFACE_WAIT_SECONDS" ]; do
		[ -r "/sys/class/net/$iface/address" ] && return 0
		sleep 1
		elapsed=$((elapsed + 1))
	done

	return 1
}

verify_lan_mac() {
	local target_mac
	local current_mac

	if ! wait_for_iface "$BRIDGE_IFACE"; then
		log_msg "WARN: $BRIDGE_IFACE is not ready, skipping LAN MAC sync"
		return 0
	fi

	if ! wait_for_iface "$LAN_IFACE"; then
		log_msg "WARN: $LAN_IFACE is not ready, skipping LAN MAC sync"
		return 0
	fi

	target_mac="$(get_iface_mac "$BRIDGE_IFACE")" || {
		log_msg "ERROR: cannot read $BRIDGE_IFACE MAC"
		return 1
	}

	if ! is_valid_mac "$target_mac"; then
		log_msg "ERROR: invalid $BRIDGE_IFACE MAC $target_mac"
		return 1
	fi

	current_mac="$(get_iface_mac "$LAN_IFACE")" || {
		log_msg "ERROR: cannot read $LAN_IFACE MAC"
		return 1
	}

	[ "$current_mac" = "$target_mac" ] || {
		log_msg "WARN: $LAN_IFACE MAC $current_mac differs from $BRIDGE_IFACE $target_mac"
	}
}

prepare_spi_device() {
	[ -L "$SPI_ALIAS" ] && rm -f "$SPI_ALIAS"

	if [ -e "$SPI_ALIAS" ]; then
		log_msg "using existing SPI device $SPI_ALIAS"
		return 0
	fi

	if [ ! -e "$SPI_SOURCE" ]; then
		log_msg "ERROR: missing SPI device $SPI_SOURCE"
		ls /dev/spidev* 2>/dev/null | logger -t "$TAG"
		return 1
	fi

	ln -sf "$SPI_SOURCE" "$SPI_ALIAS"
	log_msg "linked $SPI_ALIAS -> $SPI_SOURCE"
}

prepare_fifo() {
	rm -f "$CONTROL_FIFO"
	mkfifo "$CONTROL_FIFO" || return 1
	log_msg "control fifo ready at $CONTROL_FIFO"
}

start_usrapp() {
	if [ ! -x "$USR_APP" ]; then
		log_msg "ERROR: missing executable $USR_APP"
		return 1
	fi

	log_msg "starting usrApp for RTL9303 switch programming"
	( tail -f "$CONTROL_FIFO" | "$USR_APP" ) 2>&1 | logger -t "$TAG" &
	APP_PID="$!"

	sleep "$USRAPP_START_DELAY_SECONDS"
}

send_diag() {
	local command="$1"

	log_msg "diag: $command"
	printf '%s\n' "$command" > "$CONTROL_FIFO"
}

get_switch_mac() {
	local mac

	wait_for_iface "$BRIDGE_IFACE" || return 1
	mac="$(get_iface_mac "$BRIDGE_IFACE")" || return 1
	is_valid_mac "$mac" || return 1
	printf '%s\n' "$mac"
}

configure_l2_entries() {
	local mac="$1"
	local vid

	for vid in 1 10 20 30; do
		send_diag "l2-table add mac-ucast $vid $mac port $SWITCH_CPU_PORT"
		send_diag "l2-table set mac-ucast $vid $mac port $SWITCH_CPU_PORT static"
	done

	send_diag "l2-table set port-move sttc-port-move learn state enable"
	send_diag "l2-table set port-move sttc-port-move action drop"
}

configure_vlans() {
	local vid

	send_diag "vlan create vlan-table vid 0"
	send_diag "vlan set vlan-table vid 0 member all"
	send_diag "vlan set vlan-table vid 0 untag-port $SWITCH_CPU_PORT"

	send_diag "vlan create vlan-table vid 1"
	send_diag "vlan set vlan-table vid 1 member all"
	send_diag "vlan set vlan-table vid 1 untag-port all"
	send_diag "vlan set pvid inner port all 1"
	send_diag "vlan set pvid-mode inner port all untag-only"

	for vid in 10 20 30; do
		send_diag "vlan create vlan-table vid $vid"
		send_diag "vlan set vlan-table vid $vid member all"
	done
}

configure_eee() {
	local port

	for port in $SWITCH_LAN_PORTS; do
		send_diag "eee set port $port state enable"
	done
}

configure_leds() {
	send_diag "port set phy-mmd-reg port 8 mmd-addr 0x1E mmd-reg 0xc430 data 0xC0C0"
	send_diag "port set phy-mmd-reg port 8 mmd-addr 0x1E mmd-reg 0xc431 data 0x20"
	send_diag "port set phy-mmd-reg port 20 mmd-addr 0x1F mmd-reg 0xd032 data 0x24"
	send_diag "port set phy-mmd-reg port 20 mmd-addr 0x1F mmd-reg 0xd034 data 0x3"
	send_diag "port set phy-mmd-reg port 24 mmd-addr 0x1F mmd-reg 0xd032 data 0x24"
	send_diag "port set phy-mmd-reg port 24 mmd-addr 0x1F mmd-reg 0xd034 data 0x3"
}

configure_switch() {
	local mac

	mac="$(get_switch_mac)" || {
		log_msg "ERROR: cannot get $BRIDGE_IFACE MAC for RTL9303 L2 table"
		return 1
	}

	log_msg "programming RTL9303 switch with CPU port $SWITCH_CPU_PORT and MAC $mac"
	send_diag "port set port all state disable"
	send_diag "l2-table del all"
	configure_vlans
	configure_l2_entries "$mac"
	configure_eee
	send_diag "port set port all state enable"
	configure_leds
}

wait_usrapp() {
	local app_pid="$1"
	local status

	wait "$app_pid"
	status="$?"
	log_msg "usrApp pipeline exited with status $status"
	return "$status"
}

log_msg "initializing RTL9303 switch helper"
prepare_libraries || exit 1
verify_lan_mac || exit 1
prepare_spi_device || exit 1
prepare_fifo || exit 1
start_usrapp || exit 1
configure_switch || exit 1
wait_usrapp "$APP_PID"
