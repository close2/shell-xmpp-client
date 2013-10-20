#!/bin/sh

# cat loop | ./xmpp.sh config.txt ctrl_in ctrl_out debug.out | ncat --ssl talk.google.com 5223 | ./prepare.sh | tee loop

# create your abc@gmail.com, passwort xyz auth-text with: printf '\0abc\0xyz' | base64
# and store it in config.txt:  LOGIN_PASS=AGFiYwB4eXo=
# also add JID=abc@gmail.com
# you may add an XMPP_RESOURCE=console line as well
# eols of message/body text of the incoming stream have been replaced with this character:
# you can overwrite EOL_REPLACEMENT in the config file as well (only character not allowed is # !
EOL_REPLACEMENT=$(printf '\a')

CONFIG=$1
CTRL_IN=$2
CTRL_OUT=$3
DEBUG_FILE=$4

XMPP_RESOURCE="console"

. "$CONFIG"

# escape EOL_REPLACEMENT for sed usage
# http://stackoverflow.com/questions/407523/escape-a-string-for-sed-search-pattern
# http://backreference.org/2009/12/09/using-shell-variables-in-sed/
EOL_REPLACEMENT_SEARCH=$(printf '%s\n' "$EOL_REPLACEMENT" | sed 's/[][\.*/]/\\&/g; s/$$/\\&/; s/^^/\\&/')
EOL_REPLACEMENT_REPL=$(printf '%s\n' "$EOL_REPLACEMENT" | sed 's/[\&/]/\\&/g')

LOGIN_DOMAIN=${JID#*@}
STREAM_START="<stream:stream to=\"$LOGIN_DOMAIN\" version=\"1.0\" xmlns=\"jabber:client\" xmlns:stream=\"http://etherx.jabber.org/streams\">"
STREAM_AUTH="<auth xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\" mechanism=\"PLAIN\">$LOGIN_PASS</auth>"
STREAM_BIND="<iq id=\"bind1\" from=\"$JID\" type=\"set\"><bind xmlns=\"urn:ietf:params:xml:ns:xmpp-bind\"><resource>$XMPP_RESOURCE</resource></bind></iq>"
STREAM_PRESENCE='<presence/>'
STREAM_IQ_ERROR='<iq type="error" id="%s"><service-unavailable/></iq>'
STREAM_STATUS='<presence><status>%s</status></presence>'
STREAM_SEND_MSG='<message to="%s" type="chat"><body>%s</body></message>'
STREAM_END='</stream:stream>'

NL='
'

debug() {
	[ -z "$DEBUG_FILE" ] || printf '\n##%s\n' "$*" >> "$DEBUG_FILE"
}

p() {
	debug "$1"
	printf '%s' "$1"
}

p2() {
	printf '%s' "$1"
}

PRINTF_PID=
PRINTF_BUFFER=
ctrl_p() {
	PRINTF_BUFFER="$PRINTF_BUFFER$1$NL"
	debug "Sending $PRINTF_BUFFER to ctrl"
	if [ "$PRINTF_BUFFER" != "" ]
	then
		if [ -z $PRINTF_PID ] || ! ps $PRINTF_PID > /dev/null
		then
			debug "Sending $PRINTF_BUFFER to ctrl"
			printf '%s' "$PRINTF_BUFFER" > "$CTRL_OUT" &
			PRINTF_BUFFER=
			PRINTF_PID=$!
		else
			debug "Waiting for $PRINTF_PID to finish writing to $CTRL_OUT"
		fi
	fi
}

CTRL_READ_RESULT=
ctrl_r() {
	read -r -t 1 CTRL_READ_RESULT < "$CTRL_IN"
	[ -z "$CTRL_READ_RESULT" ] || debug "Read $CTRL_READ_RESULT from ctrl"
}

RESULT=""
nb_read() {
	local ALLOW_EMPTY=$1
	local INPUT=
	while true
	local BEFORE_LOOP=$(date +%s)
	do
		unset IN_LINE

		local IFS_BACKUP=$IFS
		IFS=

		local BEFORE=$(date +%s)
		read -r -t 2 IN_LINE
		local DIFF=$(( $(date +%s) - $BEFORE ))
		
		IFS=$IFS_BACKUP

		if [ "$IN_LINE" != "" ]
		then
			debug "$IN_LINE"
		fi

		if [ -z "$INPUT" ] && [ -z "$IN_LINE" ] && [ $DIFF -lt 1 ]
		then
			debug "EMPTY INPUT"
			debug $BEFORE
			debug $AFTER
			# if our IN_LINE is empty, but read didn't take 2 seconds
			# stdin returned an EOF → exit
			exit 1
		fi
		
		# never zero unless timeout or EOF  (see sed at the top of this file)
		if [ -z "$IN_LINE" ]
		then
			if [ ! -z "$INPUT" ] || [ ! -z "$ALLOW_EMPTY" ]
			then
				break
			fi
		else
			INPUT=$INPUT$IN_LINE
			# prevent that we never leave this loop if somebody (could be even the xmpp-server)
			# sends us something every 2 seconds
			local DIFF_LOOP=$(( $(date +%s) - $BEFORE_LOOP ))
			[ "$DIFF_LOOP" -gt 10 ] && break
		fi
        done
	RESULT=$INPUT
	if [ "$INPUT" != "" ]
	then
		debug "Read: $INPUT"
		return 0
	fi
	return 1
}

RESULT_XML_NAME=
RESULT_XML=
RESULT_REST=
# split input into 1 xml value and the rest
split_input() {
	local INPUT=$1
	local XML_NAME=$(expr match "$INPUT" '[^<]*<[[:space:]]*\([a-zA-Z0-9_]*\)')

	RESULT_XML_NAME=
	RESULT_XML=
	RESULT_REST=

	if [ ${#XML_NAME} -eq 0 ]
	then
		debug "could not extract XML name"
		return 1
	fi

	# let's try <abc ... /> first
	local XML_1=$(expr match "$INPUT" '[^<]*\(<[[:space:]]*[a-zA-Z0-9_]*\([^>]\)*/>\).*')
	if [ ${#XML_1} -gt 0 ]
	then
		debug "first version succeeded"
		debug "${#XML_1}"
		local XML_2=${INPUT:${#XML_1}}
		RESULT_XML_NAME=$XML_NAME
		RESULT_XML=$XML_1
		RESULT_REST=$XML_2
		return 0
	fi

	# didn't work, need to find <$XML_NAME...> ... </$XML_NAME>
	local XML_2=${INPUT#*</$XML_NAME>}
	if [ ${#XML_2} -ne ${#INPUT} ]
	then
		local XML_1_LENGTH=$(( ${#INPUT} - ${#XML_2} ))
		XML_1=${INPUT:0:$XML_1_LENGTH}
		RESULT_XML_NAME=$XML_NAME
		RESULT_XML=$XML_1
		RESULT_REST=$XML_2
		return 0
	fi
	debug "nothing to split, probably not enough data yet"
	return 1
}

build_error_iq() {
	local XML=$1
	RESULT=
	local TYPE=$(expr match "$XML" '[^>]*[tT][yY][pP][eE][[:space:]]*=[[:space:]]*"\([^"]\)')
	if p2 "$TYPE" | grep -i "^RESULT$" > /dev/null
	then
		return 0
	fi
	local IQ_ID=$(expr match "$XML" '[^>]*[iI][dD][[:space:]]*=[[:space:]]*"\([^"]\)')
	RESULT=$(printf "$STREAM_IQ_ERROR" "$IQ_ID")
}

MESSAGE_FROM=
MESSAGE_RESOURCE=
MESSAGE_BODY=
analyse_message() {
	local XML=$1

	MESSAGE_FROM=
	MESSAGE_BODY=

	if ! p2 "$XML" | grep -i '<body>' > /dev/null
	then
		MESSAGE_FROM=""
		MESSAGE_BODY=""
		return 1
	fi

	# <...type="error"...>
	if [ $(expr match "$XML" '[^>]*[tT][yY][pP][eE][[:space:]]*=[[:space:]]*"[eE][rR][rR][oO][rR]"') -gt 0 ]
	then
		MESSAGE_FROM=""
		MESSAGE_BODY=""
		return 1
	fi

	MESSAGE_FROM=$(expr match "$XML" '[^>]*[fF][rR][oO][mM][[:space:]]*=[[:space:]]*"\([^"]*\)"')
	MESSAGE_BODY=$(expr match "$XML" '.*<[bB][oO][dD][yY]>\(.*\)</[bB][oO][dD][yY]>')
	return 0
}

treat_message() {
	local MESSAGE_FROM=$1
	local MESSAGE_BODY=$2
	if [ "$MESSAGE_BODY" != "" ]
	then
		unescape "$MESSAGE_FROM"
		local FROM=$UNESCAPED
		unescape "$MESSAGE_BODY"
		local BODY=$UNESCAPED
		debug "Informing ctrl-channel of message"
		ctrl_p "$FROM$EOL_REPLACEMENT$BODY"
	fi
}

treat() {
	local RESP=$1
	debug "treating: $RESP"

	split_input "$RESP" || return 1

	debug "split-input:${NL}xml-name: $RESULT_XML_NAME;${NL}xml: $RESULT_XML;${NL}rest: $RESULT_REST"

	local XML_NAME=$(p2 "$RESULT_XML_NAME" | tr '[:lower:]' '[:upper:]')
	if [ "$XML_NAME" = "IQ" ]
	then
		debug "building error iq for $RESULT_XML"
		build_error_iq "$RESULT_XML"
		p "$RESULT"
		RESULT=$RESULT_REST
		return 0
	fi
	if [ "$XML_NAME" = "MESSAGE" ]
	then
		debug "received a message"
		if analyse_message "$RESULT_XML"
		then
			treat_message "$MESSAGE_FROM" "$MESSAGE_BODY"
		fi
		RESULT=$RESULT_REST
		return 0
	fi
	RESULT=$RESULT_REST
}

ESCAPED=
escape() {
	local INPUT=$1
	ESCAPED=$(p2 "$INPUT" | sed -e 's#\&#\&amp;#g' -e 's#"#\&quot;#g' -e "s#'#\\&apos;#g" -e 's#<#\&lt;#g' -e 's#>#\&gt;#g')
}

UNESCAPED=
unescape() {
	local INPUT=$1
	UNESCAPED=$(p2 "$INPUT" | sed -e 's#\&quot;#"#g' -e "s#\\&apos;#'#g" -e 's#\&lt;#<#g' -e 's#\&gt;#>#g' -e 's#\&amp;#&#g')
}

set_status() {
	debug "Setting status"
	local STATUS=$1
	escape "$STATUS"
	local STATUS_STANZA=$(printf "$STREAM_STATUS" "$ESCAPED")
	p "$STATUS_STANZA"
}

send_msg() {
	debug "Sending message"
	escape "$1"
	local TO=$ESCAPED
	escape "$2"
	local MSG=$ESCAPED
	local MSG_STANZA=$(printf "$STREAM_SEND_MSG" "$TO" "$MSG")
	p "$MSG_STANZA"
}

treat_ctrl() {
	local COMMAND=$1
	debug "treating: $COMMAND"
	case "$COMMAND" in
	END*)
		debug "end xmpp client"
		p "$STREAM_END"
		exit 0
	;;
	STATUS*)
		# just assume it is followed by EOL_REPLACEMENT:
		local STATUS_START=$(( 6 + ${#EOL_REPLACEMENT} ))
		local STATUS=""
		[ $STATUS_START -lt ${#COMMAND} ] && STATUS=${COMMAND:$STATUS_START}
		debug "status-message, status: $STATUS"
		set_status "$STATUS"
		return 0
	;;
	MESSAGE*)
		# just assume it is followed by EOL_REPLACEMENT:
		local TO_AND_TXT_START=$(( 7 + ${#EOL_REPLACEMENT} ))
		[ $TO_AND_TXT_START -lt ${#COMMAND} ] || return 1
		local TO_AND_TXT=${COMMAND:$TO_AND_TXT_START}
		TO_AND_TXT=$(p2 "$TO_AND_TXT" | sed "s/$EOL_REPLACEMENT_SEARCH/\n/g")
		local COMMAND_MESSAGE_TO=

		local BIFS=$IFS
		for i in $TO_AND_TXT
		do
			COMMAND_MESSAGE_TO=$i
			break
		done
		IFS=$BIFS

		# +1 already added for \n
		local TO_LENGTH=$(( ${#COMMAND_MESSAGE_TO} + 1 ))
		# could probably be even higher than 3
		[ $TO_LENGTH -gt 3 ] || return 2
		
		local COMMAND_MESSAGE_TXT=${TO_AND_TXT:$TO_LENGTH}
		
		debug "message to send, to: $COMMAND_MESSAGE_TO"
		debug "message is: $COMMAND_MESSAGE_TXT"
		send_msg "$COMMAND_MESSAGE_TO" "$COMMAND_MESSAGE_TXT"
		return 0
	;;
	esac

	debug "unknown message"
}

cut_stream_start() {
	local INPUT=$1
	local INPUT_WO_STREAM_START=$(expr match "$INPUT" '[[:space:]]*<[^>]*>\(.*\)')
	if [ $? -eq 0 ]
	then
		debug "Removed opening <>"
		RESULT=$INPUT_WO_STREAM_START
		return 0
	fi
	return 1
}

### MAIN ###
if [ -z "$CTRL_IN" ] || [ -z "$CTRL_OUT" ]
then
	debug "No control streams"
	exit 2
fi

if [ ! -z "$DEBUG_FILE" ]
then
	echo -n  > "$DEBUG_FILE"
fi

# start stream
p "$STREAM_START"
nb_read
p "$STREAM_AUTH"
# just dump everything we get from the xmpp server
# if this doesn't work, we don't know how to handle errors anyway
# and the xmpp server will disconnect us if we do something stupid
while true
do
	nb_read "allow_empty" || break
done

p "$STREAM_START"
# again, just ignore the <stream:stream> answer
BEFORE=$(date +%s)
AFTER=$BEFORE
debug "throwing away everything from our input stream for the next 10 seconds"
while [ "$(( $AFTER - $BEFORE ))" -lt 10 ]
do
	nb_read "allow_empty"
	AFTER=$(date +%s)
done

p "$STREAM_BIND"
nb_read
RESP=$RESP$RESULT

p "$STREAM_PRESENCE"
nb_read
RESP=$RESP$RESULT

ctrl_p "READY"

while true
do
	nb_read "allow_empty"
	RESP=$RESP$RESULT
	while [ ! -z "$RESP" ]
	do
		treat "$RESP" || break;
		RESP=$RESULT
	done

	ctrl_r
	if [ "$CTRL_READ_RESULT" != "" ]
	then
		treat_ctrl "$CTRL_READ_RESULT"
		CTRL_READ_RESULT=
	fi
done

