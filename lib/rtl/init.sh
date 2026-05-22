#!/bin/ash

TAG="rtl9303"
CONTROL_FIFO="/tmp/control_rtl9303.fifo"
SPI_SOURCE="/dev/spidev1.0"
SPI_ALIAS="/dev/spidev32765.0"
USR_APP="/lib/rtl/usrApp"

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
prepare_spi_device || exit 1
prepare_fifo || exit 1
run_usrapp
