#!/bin/sh
# either change _SERVER and _PORT in this script, or
# add _SERVER=xxx
# _PORT=yyy
# in the config file
# (you can overwrite all variables in the config file)
# ./bot.sh config.sh bot_functions.sh debug.out

_EXEC_PATH=$(dirname $0)

_SERVER="talk.google.com"
_PORT="5223"
# path to ncat is not allowed to have spaces!
# Otherwise split _NCAT into _NCAT and _NCAT_FLAGS...
_NCAT="ncat --ssl"

# # is not allowed as replacement character
EOL_REPLACEMENT=$(printf '\a')

XMPP_CLIENT="$_EXEC_PATH/xmpp.sh"

BOT2XMPP_FIFO=/tmp/bot2xmpp.fifo.$$
XMPP2BOT_FIFO=/tmp/xmpp2bot.fifo.$$

LOOP_FIFO=/tmp/loop.fifo.$$

_CONFIG="$1"
[ -z "$_CONFIG" ] && _CONFIG="$_EXEC_PATH/config.sh"
. "$_CONFIG"


# escape EOL_REPLACEMENT for sed usage
# http://stackoverflow.com/questions/407523/escape-a-string-for-sed-search-pattern
# http://backreference.org/2009/12/09/using-shell-variables-in-sed/
_EOL_REPLACEMENT_SEARCH=$(printf '%s\n' "$EOL_REPLACEMENT" | sed 's/[][\.*/]/\\&/g; s/$$/\\&/; s/^^/\\&/')
_EOL_REPLACEMENT_REPL=$(printf '%s' "$EOL_REPLACEMENT" | sed 's/[\&/]/\\&/g')


_DEBUG_FILE=$3
debug() {
	[ -z "$_DEBUG_FILE" ] || printf '%s\n' "$1" > "$_DEBUG_FILE"
}

_NL="
"

# make temporary fifos:
debug "Creating $BOT2XMPP_FIFO"
mkfifo "$BOT2XMPP_FIFO"
debug "Creating $XMPP2BOT_FIFO"
mkfifo "$XMPP2BOT_FIFO"

debug "Creating $LOOP_FIFO"
mkfifo "$LOOP_FIFO"

# if no process is writing to the control input,
# our client might hang (even with the -t timeout flag
cat > "$BOT2XMPP_FIFO" &
_B2X_PID=$!
cat > "$XMPP2BOT_FIFO" &
_X2B_PID=$!

clean_up() {
	kill $_B2X_PID
	kill $_X2B_PID

	kill $_XMPP_CLIENT_PID 2>/dev/null

	rm "$BOT2XMPP_FIFO"
	rm "$XMPP2BOT_FIFO"
	rm "$LOOP_FIFO"
}

trap clean_up 0 1 2 3 6

_prepare() {
	local BIFS=$IFS
	IFS=
	local CHAR_IN=
	while true
	do
		read -r -n1 CHAR_IN || exit 1
		if [ -z "$CHAR_IN" ]
		then
			printf '%s' "$EOL_REPLACEMENT"
			continue
		fi
		if [ "$CHAR_IN" = ">" ]
		then
			printf '>\n'
			continue
		fi
		echo -n "$CHAR_IN"
	done
	IFS=$BIFS
}

_XMPP_CLIENT_PID=
_start_xmpp_client() {
	# < "$BOT2XMPP_FIFO" would probably also work
	debug "Starting xmpp-client: "
	debug "(cat \"$LOOP_FIFO\" | \"$XMPP_CLIENT\" \"$_CONFIG\" \"$BOT2XMPP_FIFO\" \"$XMPP2BOT_FIFO\" \"$_DEBUG_FILE\" | $_NCAT \"$_SERVER\" \"$_PORT\" | _prepare > \"$LOOP_FIFO\" )&"
	(cat "$LOOP_FIFO" | "$XMPP_CLIENT" "$_CONFIG" "$BOT2XMPP_FIFO" "$XMPP2BOT_FIFO" "$_DEBUG_FILE" | $_NCAT "$_SERVER" "$_PORT" | _prepare > "$LOOP_FIFO" )&
	_XMPP_CLIENT_PID=$!
	debug "Client pid: $_XMPP_CLIENT_PID"
}

p2() {
	printf '%s' "$1"
}

p_bot2xmpp() {
	debug "Sending message to xmpp: $1"
	printf '%s\n' "$1" > "$BOT2XMPP_FIFO"
}

debug "Importing bot functions"
_BOT_FUNCTIONS="$2"
[ -z "$_BOT_FUNCTIONS" ] && _BOT_FUNCTIONS="$_EXEC_PATH/bot_functions.sh"
debug ". $_BOT_FUNCTIONS"
. "$_BOT_FUNCTIONS"

debug "calling _start_xmpp_client"
_start_xmpp_client

_repl_eol() {
	# thanks http://stackoverflow.com/questions/1251999/sed-how-can-i-replace-a-newline-n
	p2 "$MESSAGE" | sed ":a;N;\$!ba;s/\n/$_EOL_REPLACEMENT_REPL/g"
}

send_message() {
	local TO=$1
	local RESOURCE=$2
	local MESSAGE=$3
	[ -z "$RESOURCE" ] || TO="$TO/$RESOURCE"
	debug "Sending message: $TO$_NL$MESSAGE"

	MESSAGE=$(_repl_eol "$MESSAGE")
	local COMPLETE_MESSAGE=$(printf 'MESSAGE%s%s%s%s' "$EOL_REPLACEMENT" "$TO" "$EOL_REPLACEMENT" "$MESSAGE")
	p_bot2xmpp "$COMPLETE_MESSAGE"
}

set_status() {
	local STATUS=$1
	STATUS=$(_repl_eol "$STATUS")
	debug "Setting status: $STATUS"
	local COMPLETE_MESSAGE=$(printf 'STATUS%s%s' "$EOL_REPLACEMENT" "$STATUS")
	p_bot2xmpp "$COMPLETE_MESSAGE"
}

# wait for ok to continue
read -r _INCOMING_MESSAGE < "$XMPP2BOT_FIFO"
_INCOMING_MESSAGE=

while true
do
	read -r -t 1 _INCOMING_MESSAGE < "$XMPP2BOT_FIFO"
	if [ ! -z "$_INCOMING_MESSAGE" ]
	then
		debug "Received message: $_INCOMING_MESSAGE"
		# ^FROM${EOL_REPLACEMENT}RESOURCE${EOL_REPLACEMENT}Message${EOL_REPLACEMENT}over${EOL_REPLACEMENT}multiple${EOL_REPLACEMENT}lines$
		_INCOMING_MSG_REPL=$(p2 "$_INCOMING_MESSAGE" | sed "s/$_EOL_REPLACEMENT_SEARCH/DONALD_DUCK15048_1/")
		debug "Message replaced: $_INCOMING_MSG_REPL"
		
		_FROM=$(p2 "$_INCOMING_MSG_REPL" | sed 's/^\(.*\)DONALD_DUCK15048_1.*$/\1/')
		_UNSEP_MESSAGE=$(p2 "$_INCOMING_MSG_REPL" | sed "s/$_EOL_REPLACEMENT_SEARCH/DONALD_DUCK15048_1/" | sed 's/^.*DONALD_DUCK15048_1\(.*\)$/\1/')
		_MESSAGE=$(p2 "$_UNSEP_MESSAGE" | sed "s/$_EOL_REPLACEMENT_SEARCH/\n/g")

		debug "Treating message: $_FROM$_NL$_MESSAGE"
		type treat_incoming_message &>/dev/null && treat_incoming_message "$_FROM" "$_MESSAGE"
	else
		if ! ps $_XMPP_CLIENT_PID > /dev/null
		then
			# xmpp client died
			debug "Client died ($_XMPP_CLIENT_PID)"
			type xmpp_client_died &>/dev/null && xmpp_client_died $_XMPP_CLIENT_PID
			# fixme restart
		fi
	fi
	debug "Pulling for input"
	type pull_for_input &>/dev/null && pull_for_input
	debug "Asking if we should stop loop"
	type stop_message_loop &>/dev/null && stop_message_loop && break
done

debug "Outside loop; Shutting down"

if ps $_XMPP_CLIENT_PID > /dev/null
then
	debug "Sending END to client"
	p_bot2xmpp "END"
	sleep 5
fi

# do I need this?
clean_up
