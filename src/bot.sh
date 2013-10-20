#!/bin/sh

end_now=0
message_received() {
	local from=$1
	local message=$2
	debug "$message"
	local reply_msg=$(printf "You said: %s" "$message")
	send_msg "$from" "$reply_msg"
	[ "$message" = "END NOW" ] && end_now=1
	debug "END NOW: $end_now"
}


last_time_status=$(date +%s)
poll() {
	local now=$(date +%s)
	local diff=$(( $now - $last_time_status ))
	if [ "$diff" -gt 30 ]
	then
		last_time_status=$now
		local message=$(printf "Set by command line shell client :)\nUptime: %s" "$(uptime)")
		set_status "$message"
	fi
	debug "returning END NOW: $end_now"
	return $end_now
}

debug() {
	printf "%s\n" "$1" > debug.out
	true
}

. ./xmpp.sh

start_xmpp "$1" "$2"

