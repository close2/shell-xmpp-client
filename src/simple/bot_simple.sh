#!/bin/sh

XMPP_SIMPLE="$(dirname $0)/xmpp_simple.sh"
JID=xmpp@delta64.com
PASS_FILE="$(dirname $0)/pass"

nl=$'\n'

IFS="$nl"

message_received() {
	local from=$1
	local message=$2

	if [ "$message" = "disconnect" ]
	then
		disconnect
	else
		send_msg $1 "I can say that too:$nl$message"
	fi
}

xmpp_control_mode() {
	set_status "My systems time: $(date)"
}


jid="$JID"
login_pass="$(cat $PASS_FILE)"

# only announce our system time every 60 seconds
control_mode_every=60

### INSERT XMPP_SIMPLE HERE ###
. "$XMPP_SIMPLE"

