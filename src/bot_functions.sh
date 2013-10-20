END_NOW=0
treat_incoming_message() {
	echo "Incoming message"
	printf "From: %s\n--\n" "$1"
	printf "Resource: %s\n--\n" "$2"
	local BIFS="$IFS"
	printf "Message: %s\n--\n" "$3"
	IFS="$BIFS"
	echo "Sending the same message back"
	send_message "$1" "$2" "You said: $3"

	if [ "$3" = "END NOW" ]
	then
		END_NOW=1
	fi
}

xmpp_client_died() {
	echo "xmpp client died"
	exit 3
}

LAST_TIME=$(date +%s)
LAST_TIME_STATUS=$LAST_TIME
pull_for_input() {
	echo "Pull for input has been called"
	local NOW=$(date +%s)
	local DIFF=$(( $NOW - $LAST_TIME ))
	if [ "$DIFF" -gt 60 ]
	then
		LAST_TIME=$NOW
		local MESSAGE="Current epoch time: $(date +%s)"
		send_message christian@loitsch.com "" "$MESSAGE"
	fi
	DIFF=$(( $NOW - $LAST_TIME_STATUS ))
	if [ "$DIFF" -gt 90 ]
	then
		LAST_TIME_STATUS=$NOW
		local MESSAGE=$(printf "Set by command line shell client :)\nUptime: %s" "$(uptime)")
		set_status "$MESSAGE"
	fi
}

stop_message_loop() {
	if [ "$END_NOW" = "1" ]
	then
		echo "Should I stop the message loop?  Yes :,-(   (replying with 0)"
		return 0
	fi
	
	echo "Should I stop the message loop?  No of course not (replying with 1)"
	return 1
}

