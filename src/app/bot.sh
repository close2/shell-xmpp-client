#!/bin/sh

XMPP="$(dirname $0)/xmpp.sh"
JID=xmpp@delta64.com
PASS_FILE="$(dirname $0)/pass"

nl=$'\n'
IFS="$nl"

# start xmpp
unset XMPP_SOCKET_LOOP ; unset XMPP_SOCKET_CTRL ; unset XMPP_SOCKET_REPLY
eval `$XMPP --connect --jid "$JID" --pass-file "$PASS_FILE" --debug-file /tmp/xmpp-debug`

declare -i count=0
while true
do
	incoming=$($XMPP --next-msg --debug-file /tmp/xmpp-debug)
	echo "Incoming: $incoming"

	from=
	message=
	tmp_nl=
        for line in $incoming
        do
		if [ "$from" = "" ]
		then
			from="$line"
		else
			message="$message$tmp_nl$line"
			tmp_nl=$nl
		fi
        done
	echo "From: $from"
	echo "Message: $message"

	if [ "$message" = "disconnect" ]
	then
		$XMPP --disconnect
	fi

	echo "Trying to send msg"
	$XMPP --msg "$from" "I can say that too!:$nl$message" --debug-file /tmp/xmpp-debug

	count=$count+1
	echo "Trying to set status"
	$XMPP --set-status "I have replied to $count messages!" --debug-file /tmp/xmpp-debug
done

trap "$XMPP --disconnect" EXIT

