#!/bin/ash

TAG="rtl9303"
CONTROL_FIFO="/tmp/control_rtl9303.fifo"
SPI_SOURCE="/dev/spidev1.0"
SPI_ALIAS="/dev/spidev32765.0"
USR_APP="/lib/rtl/usrApp"
LAN_IFACE="lan"
BRIDGE_IFACE="br-lan"
IFACE_WAIT_SECONDS=30

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

sync_lan_mac() {
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

	if [ "$current_mac" = "$target_mac" ]; then
		log_msg "$LAN_IFACE MAC already matches $BRIDGE_IFACE: $target_mac"
		return 0
	fi

	log_msg "setting $LAN_IFACE MAC from $current_mac to $target_mac"
	ip link set dev "$LAN_IFACE" down || return 1
	ip link set dev "$LAN_IFACE" address "$target_mac" || return 1
	ip link set dev "$LAN_IFACE" up || return 1
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

run_usrapp() {
	local app_pid
	local status

	if [ ! -x "$USR_APP" ]; then
		log_msg "ERROR: missing executable $USR_APP"
		return 1
	fi

	log_msg "starting usrApp and keeping it alive for LAN hotplug"
	( tail -f "$CONTROL_FIFO" | "$USR_APP" ) 2>&1 | logger -t "$TAG" &
	app_pid="$!"

	wait "$app_pid"
	status="$?"
	log_msg "usrApp pipeline exited with status $status"
	return "$status"
}

log_msg "initializing RTL9303 switch helper"
prepare_libraries || exit 1
sync_lan_mac || exit 1
prepare_spi_device || exit 1
prepare_fifo || exit 1
run_usrapp
