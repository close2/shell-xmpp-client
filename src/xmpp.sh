#!/bin/bash

# get debug_file from arguments _or_ ENV
# loop_fifo

calledWith="$0 $*"
debug() {
	[ -z "$debug_file" ] || printf '%s\n' "$1" >> "$debug_file"
}

# first parse env-variables
debug_file="$XMPP_DEBUG_FILE"
fifo_control=${XMPP_SOCKET_CTRL:-"/tmp/xmpp.$$/fifo.control"}
fifo_reply=${XMPP_SOCKET_REPLY:-"/tmp/xmpp.$$/fifo.reply"}
fifo_loop=${XMPP_SOCKET_LOOP:-"/tmp/xmpp.$$/fifo.loop"}

# then set some variables we probably never change
nl='
'

IFS="$nl"

# we use \a for both, as control_mode_char and as a temporary replacement for \n
# using \a instead of \n simplifies sed and grep usage.  While reading the stream,
# we simply append \a instead of \n and replace all \a after treatment with \n
# (They could be different characters!)
control_mode_char=$(printf '\a')
eol_replacement=$(printf '\a')

jid=
login_pass=
resource="console"
ncat="ncat --ssl talk.google.com 5223"

# Commands
cmd_connect="connect"
cmd_message="msg"
cmd_status="set-status"
cmd_msg_count="msg-count"
cmd_next_msg="next-msg"
cmd_help="help"
cmd_gen_pass="generate-password"
cmd_disconnect="disconnect"
arg_jid="jid"
arg_pass="pass"
arg_pass_file="pass-file"
arg_resource="resource"
arg_ncat="ncat"
arg_fifo_loop="fifo-loop"
arg_fifo_reply="fifo-reply"
arg_fifo_control="fifo-control"
arg_no_eval_output="no-eval-output"
arg_debug_file="debug-file"

# printUsage
printUsage() {
	echo "USAGE:"
	echo "* Start connection:"
	echo "	$0 --$cmd_connect --$arg_jid jid [--$arg_resource console] {--$arg_pass password | --$arg_pass_file file} [--$arg_ncat \"ncat --ssl talk.google.com 5223\"]"
	echo "	Example: $0 --$cmd_connect --$arg_jid bot@gmail.com --$arg_pass_file ~/.gmail_password"
	echo "	  Possible optional arguments:"
	echo "	    --$arg_no_eval_output: don't output eval commands"
	echo "	    --$arg_fifo_loop, --$arg_fifo_reply, --$arg_fifo_control: specify names for fifos"
	echo "	    --$arg_debug_file: debug output will be appended to this file (stderr would be /dev/fd/2)"
	echo "* Get number of messages waiting for retrieval:"
	echo "	$0 --$cmd_msg_count"
	echo "	Example: $0 --$cmd_msg_count"
	echo "    Example Output:"
	echo "      2"
	echo "* Retrieve (and remove) next message:"
	echo "	$0 --$cmd_next_msg"
	echo "	Example: $0 --$cmd_next_msg"
	echo "    Example Output:"
	echo "      somebody@gmail.com/resource1"
	echo "      actual message"
	echo "      possibly over multiple lines"
	echo "* Send message:"
	echo "	$0 --$cmd_message to_jid txt"
	echo "	Example: $0 --$cmd_message somebody@gmail.com \"\$(printf 'Hello\nnice to see you')\""
	echo "* Set status:"
	echo "	$0 --$cmd_status txt"
	echo "	Example: $0 --$cmd_status \"bot is waiting\""
	echo "* Disconnect:"
	echo "  $0 --$cmd_disconnect"
	echo "* Generate password for either --$arg_pass or for --$arg_pass_file"
	echo "	$0 --$cmd_gen_pass"
	echo "* Print this help:"
	echo "	$0 --help"
	echo
	echo
}

# then parse options and overwrite default values
cmd=
argument1=
argument2=
output_eval="t"
while [ "$1" != "" ]
do
	case "$1" in
		"--$arg_pass_file")
			login_pass="$(cat $2)"
			shift 2
			;;
		"--$arg_pass")
			login_pass="$2"
			shift 2
			;;
		"--$arg_jid")
			jid="$2"
			shift 2
			;;
		"--$arg_resource")
			resource="$2"
			shift 2
			;;
		"--$arg_ncat")
			ncat="$2"
			shift 2
			;;
		"--$arg_fifo_loop")
			fifo_loop="$2"
			shift 2
			;;
		"--$arg_fifo_reply")
			fifo_reply="$2"
			shift 2
			;;
		"--$arg_fifo_control")
			fifo_control="$2"
			shift 2
			;;
		"--$arg_no_eval_output")
			output_eval="f"
			shift 1
			;;
		"--$arg_debug_file")
			debug_file="$2"
			shift 2
			;;
		"--$cmd_connect")
			cmd="$cmd_connect"
			shift 1
			;;
		"--$cmd_message")
			cmd="$cmd_message"
			argument1="$2"
			argument2="$3"
			shift 3
			;;
		"--$cmd_status")
			cmd="$cmd_status"
			argument1="$2"
			shift 2
			;;
		"--$cmd_msg_count")
			cmd="$cmd_msg_count"
			shift 1
			;;
		"--$cmd_next_msg")
			cmd="$cmd_next_msg"
			shift 1
			;;
		"--$cmd_gen_pass")
			cmd="$cmd_gen_pass"
			shift 1
			;;
		"--$cmd_disconnect")
			cmd="$cmd_disconnect"
			shift 1
			;;
		"--$cmd_help")
			if [ "$cmd" = "" ]
			then
				cmd="$cmd_help"
			fi
			printUsage
			shift 1
			;;
		*)
			echo "$0: unparseable option $1"
			printUsage
			exit 1
			;;
	esac
done

[ -z "$debug_file" ] || export XMPP_DEBUG_FILE=$debug_file


# _xmpp
#   processes the incoming stream.
#   If it receives an \a character interrupts and switches to control-mode
#   i.e. reads from control fifo, acts on command and then continues to process
#   normal xmpp stream.
#   In control mode _xmpp should never block and control
#   commands are therefore designed that _xmpp always knows if there is a next line for the command.
#
# The fifos:
#   fifo_loop:
#     connects the output of ncat to the input of _xmpp (via _prepare_input).  It is also
#     used to inform _xmpp that a new command is waiting on the control_fifo.
#   fifo_control:
#     by writing 'message\nto\nthis\nis a multi-line message\n.\n' into this pipe and
#     then sending a \a into the loop fifo _xmpp switches from message processing
#     to control mode where it processes the command.
#     Every entity which might be longer than one line has to end with '.\n' (which will
#     be discarded.  '..' on the beginning of a line will be replaced with '.'.
#   fifo_reply:
#     if the control mode of _xmpp wants to send anything back to the caller it writes to this
#     fifo.  As _xmpp should never block in control mode the caller _must_ read the answer
#     immediately.  The replies are designed in a way to prevent blockage for the caller as well.
#

_xmpp_p() {
	debug "$1"
	printf '%s' "$1"
}

_xmpp_p2() {
	printf '%s' "$1"
}

_xmpp_reply_p() {
	debug "To reply fifo: $1"
	if [ -z "$2" ]
	then
		printf '%s' "$1"
	else
		printf '%s\n' "$1"
	fi
}

_xmpp() {
	local jid=$1
	local resource=$2
	local login_pass=$3
	local fifo_control=$4
	local fifo_reply=$5
	
        # see generate password comment on how to build the password
	# login_pass=AGFiYwB4eXo=
	# jid=abc@gmail.com
	# resource=console
	
	# escape eol_replacement for sed usage
	# http://stackoverflow.com/questions/407523/escape-a-string-for-sed-search-pattern
	# http://backreference.org/2009/12/09/using-shell-variables-in-sed/
	local eol_replacement_search=$(printf '%s\n' "$eol_replacement" | sed 's/[][\.*/]/\\&/g; s/$$/\\&/; s/^^/\\&/')
	local eol_replacement_repl=$(printf '%s\n' "$eol_replacement" | sed 's/[\&/]/\\&/g')
	
	local login_domain=${jid#*@}
	local stream_start="<stream:stream to=\"$login_domain\" version=\"1.0\" xmlns=\"jabber:client\" xmlns:stream=\"http://etherx.jabber.org/streams\">"
	local stream_auth="<auth xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\" mechanism=\"PLAIN\">$login_pass</auth>"
	local stream_bind="<iq id=\"bind1\" from=\"$jid\" type=\"set\"><bind xmlns=\"urn:ietf:params:xml:ns:xmpp-bind\"><resource>$resource</resource></bind></iq>"
	local stream_presence='<presence/>'
	local stream_iq_error='<iq type="error" id="%s"><service-unavailable/></iq>'
	local stream_status='<presence><status>%s</status></presence>'
	local stream_send_msg='<message to="%s" type="chat"><body>%s</body></message>'
	local stream_end='</stream:stream>'
	
	local escaped=
	_xmpp_escape() {
		local input=$1
		escaped=$(_xmpp_p2 "$input" | sed -e 's#\&#\&amp;#g' -e 's#"#\&quot;#g' -e "s#'#\\&apos;#g" -e 's#<#\&lt;#g' -e 's#>#\&gt;#g')
	}
	
	local unescaped=
	_xmpp_unescape() {
		local input=$1
		unescaped=$(_xmpp_p2 "$input" | sed -e 's#\&quot;#"#g' -e "s#\\&apos;#'#g" -e 's#\&lt;#<#g' -e 's#\&gt;#>#g' -e 's#\&amp;#&#g')
	}
	
	local received_messages=""
	local received_messages_count=0
	_message_received() {
		local from=$1
		local message=$2
		local message_dot=""
		received_messages="$received_messages$from$nl"
		for line in $message
		do
			if [ "${line:0:1}" = "." ]
			then
				received_messages="${received_messages}.$line$nl"
			else
				received_messages="${received_messages}$line$nl"
			fi
		done
		received_messages="${received_messages}.$nl"
		debug "new received messages: »$received_messages«"
		received_messages_count=$(( $received_messages_count + 1 ))
	}
	
        local autoEnterControlMode=
	# return values: 0 means continue; 1 means disconnect
	_xmpp_control_mode() {
		debug "Entering control mode (fifo: $fifo_control)"
		# read one command from fifo_control and send reply to fifo_reply
		local in_line=$1
		local from=""
		local to=""
		local txt=""
		local line=""
		local line_counter=0

                autoEnterControlMode=

                # only not empty if autoEnter?
                if [ "$in_line" = "" ]
		then
			debug "Opening fifo_control read/write"
			# we have to close fifo_control before sending our reply
			# otherwise we have a race condition, where the command receives
			# for instance the message count, sends another command, even though
			# we haven't closed fifo_control yet.  The $control_mode_char will
			# not block (fifo_loop is also opened with <>).
			# We possibly close fifo_control right after the new command,
			# effectively discarding it.  We will however read the $control_mode_char
			# and reenter control_mode waiting for a command we discarded by
			# closing fifo_control too late.
			exec 20<>$fifo_control
			# there must be a command in fifo control (we have received a single \a)
			debug "control mode, read from fifo ($$)"
			read -r in_line < $fifo_control
			debug "Read from control »$in_line«"
                else
			debug "was called because of autoEnter with Command: »$in_line«"
                fi
		if [ "$in_line" = "$cmd_msg_count" ]
		then
			exec 20<&-
			debug "Sending message count: $received_messages_count"
			_xmpp_reply_p "$received_messages_count" "nl" > $fifo_reply
		fi
		if [ "$in_line" = "$cmd_disconnect" ]
		then
			debug "Disconnect! Returning from _xmpp_control_mode with 1"
			# just to be sure close fifo_control
			exec 20<&-
			return 1;
		fi
		if [ "$in_line" = "$cmd_next_msg" ]
		then
			exec 20<&-
			if [ "$received_messages_count" -gt "0" ]
			then
				received_messages_count=$(( $received_messages_count - 1 ))
				local ifsBackup="$IFS"
				IFS="$nl"
				for line in $received_messages
				do
					_xmpp_reply_p "$line" "nl" > "$fifo_reply"
					debug "sent to reply fifo (line $line_counter)"
					line_counter=$(( $line_counter + 1 ))
					if [ "$line" = "." ]
					then
						break
					fi
				done
				debug "done sending to fifo reply"
				line_counter=$(( $line_counter + 1 ))
				received_messages=$(printf '%s' "$received_messages" | tail -n "+$line_counter" )
				IFS="$ifsBackup"
                        else
                                autoEnterControlMode="$cmd_next_msg"
			fi
		fi

		_read_txt_block() {
			local line=""
			while true
			do
				debug "_read_txt_block, read from fifo ($$)"
				read -r line < "$fifo_control"
				debug "read: $line"
				if [ "$line" = "." ]
				then
					break
				fi
				if [ "${line:0:1}" = "." ]
				then
					txt="$txt$nl${line:1}"
				else
					txt="$txt$nl$line"
				fi
			done
			debug "_read_txt_block done: $txt"
		}
		if [ "$in_line" = "$cmd_message" ]
		then
			debug "read to (message), read from fifo ($$)"
			read -r to < "$fifo_control"
			debug "  to $to"
			_read_txt_block
			_send_msg "$to" "$txt"
			exec 20<&-
			_xmpp_reply_p "OK" "nl" > $fifo_reply
		fi
		if [ "$in_line" = "$cmd_status" ]
		then
			debug "read txt (status), read from fifo ($$)"
			_read_txt_block
			_set_status "$txt"
			exec 20<&-
			_xmpp_reply_p "OK" "nl" > $fifo_reply
		fi
		debug "Returning from _xmpp_control_mode with 0"
		# close file-descriptor again (should already be closed!)
		exec 20<&-
		return 0;
	}

	# tmp_in_line is only used if we are called with a timeout
	# in that case we avoid having incomplete data in in_line.
	# We store that incomplete data in in_line for the next call to _xmpp_read.
	# This function does not know if there was a timeout or if there was only a
	# new line character.  But timeout is only used in situations where this
	# doesn't matter
	# return values:
	#   0: data received / available
	#   1: no data received (propably timeout)
	#   100: _xmpp_control told us to disconnect
	#   101: nothing received, other side probably disconnected
	local tmp_in_line=""
	local result=""
	_xmpp_read() {
		local timeout=$1
		local ifs_backup="$IFS"
		IFS=
	
		local char_in=

		[ "$autoEnterControlMode" = "" ] || _xmpp_control_mode "$autoEnterControlMode"

		[ -z "$tmp_in_line" ] || result="$tmp_in_line"

		unset tmp_in_line
	
		while true
		do
			if [ -z "$timeout" ]
			then
				if ! read -r -n1 char_in
				then
					debug "Didn't read anything.  Loop fifo apparently 'dead'."
					IFS="$ifs_backup"
					return 101
				fi
			else
				read -r -n1 -t $timeout char_in
				if [ -z "$char_in" ] # read \n or timeout
				then
					tmp_result="$in_line"
					unset result
					IFS="$ifs_backup"
					return 1
				fi
			fi
	
			if [ "$char_in" = "$control_mode_char" ]
			then
				autoEnterControlMode=
				if ! _xmpp_control_mode
				then
					debug "_xmpp_control_mode told us to disconnect, returning with 100"
					IFS="$ifs_backup"
					return 100
				fi
				continue
			fi

			
			[ -z "$char_in" ] && char_in="$eol_replacement" # read \n

			result="$result$char_in"

			if [ "$char_in" = '>' ]
			then
				IFS="$ifs_backup"
				return 0
			fi
		done
	}

	local result_xml_name=
	local result_xml=
	local result_rest=
	# split input into 1 xml value and the rest
	_xmpp_split_input() {
		local input=$1
		local xml_name=$(expr match "$input" '[^<]*<[[:space:]]*\([a-zA-Z0-9_]*\)')
	
		result_xml_name=
		result_xml=
		result_rest=
	
		if [ ${#xml_name} -eq 0 ]
		then
			debug "could not extract XML name"
			return 1
		fi
	
		# let's try <abc ... /> first
		local xml_1=$(expr match "$input" '[^<]*\(<[[:space:]]*[a-zA-Z0-9_]*\([^>]\)*/>\).*')
		if [ ${#xml_1} -gt 0 ]
		then
			debug "first version succeeded"
			debug "${#xml_1}"
			local xml_2=${input:${#xml_1}}
			result_xml_name=$xml_name
			result_xml=$xml_1
			result_rest=$xml_2
			return 0
		fi
	
		# didn't work, need to find <$xml_name...> ... </$xml_name>
		local xml_2=${input#*</$xml_name>}
		if [ ${#xml_2} -ne ${#input} ]
		then
			local xml_1_length=$(( ${#input} - ${#xml_2} ))
			xml_1=${input:0:$xml_1_length}
			result_xml_name=$xml_name
			result_xml=$xml_1
			result_rest=$xml_2
			return 0
		fi
		debug "nothing to split, probably not enough data yet"
		return 1
	}
	
	_xmpp_build_error_iq() {
		local xml=$1
		result=
		local xml_type=$(expr match "$xml" '[^>]*[tT][yY][pP][eE][[:space:]]*=[[:space:]]*"\([^"]\)')
		if _xmpp_p2 "$xml_type" | grep -i "^RESULT$" > /dev/null
		then
			return 0
		fi
		local iq_id=$(expr match "$xml" '[^>]*[iI][dD][[:space:]]*=[[:space:]]*"\([^"]*\)"')
		result=$(printf "$stream_iq_error" "$iq_id")
	}

	
	local message_from=
	local message_body=
	_xmpp_analyze_message() {
		local xml=$1
	
		message_from=
		message_body=
	
		if ! _xmpp_p2 "$xml" | grep -i '<body>' > /dev/null
		then
			message_from=""
			message_body=""
			return 1
		fi
	
		# <...type="error"...>
		if [ $(expr match "$xml" '[^>]*[tT][yY][pP][eE][[:space:]]*=[[:space:]]*"[eE][rR][rR][oO][rR]"') -gt 0 ]
		then
			message_from=""
			message_body=""
			return 1
		fi
	
		message_from=$(expr match "$xml" '[^>]*[fF][rR][oO][mM][[:space:]]*=[[:space:]]*"\([^"]*\)"')
		message_body=$(expr match "$xml" '.*<[bB][oO][dD][yY]>[[:space:]]*\(.*\)</[bB][oO][dD][yY]>' | sed -e "s/$eol_replacement_search/\n/g" -e 's/[ \t]*$//')
		_xmpp_unescape "$message_body"
		message_body=$unescaped
		debug "Message from $message_from: $message_body"
		return 0
	}
	
	_xmpp_treat() {
		local resp=$1
		debug "treating: $resp"
	
		_xmpp_split_input "$resp" || return 1
	
		debug "split-input:${nl}xml-name: $result_xml_name;${nl}xml: $result_xml;${nl}rest: $result_rest"
	
		local xml_name=$(_xmpp_p2 "$result_xml_name" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
		if [ "$xml_name" = "IQ" ]
		then
			debug "building error iq for $result_xml"
			_xmpp_build_error_iq "$result_xml"
			_xmpp_p "$result"
			result=$result_rest
			return 0
		fi
		if [ "$xml_name" = "MESSAGE" ]
		then
			debug "received a message"
			if _xmpp_analyze_message "$result_xml"
			then
				_message_received "$message_from" "$message_body"
			fi
			result=$result_rest
			return 0
		fi
		result=$result_rest
	}
	
	_set_status() {
		debug "Setting status"
		local status_msg=$1
		_xmpp_escape "$status_msg"
		local status_stanza=$(printf "$stream_status" "$escaped")
		_xmpp_p "$status_stanza"
	}
	
	_send_msg() {
		debug "Sending message"
		_xmpp_escape "$1"
		local to=$escaped
		_xmpp_escape "$2"
		local message=$escaped
		local msg_stanza=$(printf "$stream_send_msg" "$to" "$message")
		_xmpp_p "$msg_stanza"
	}

	_disconnect() {
		_xmpp_p "$stream_end"
		exit $1
	}
	
	### MAIN ###
	local ret
	# start stream
	_xmpp_p "$stream_start"
	_xmpp_read
	ret=$?; [ $ret -gt 2 ] && _disconnect $ret
	_xmpp_p "$stream_auth"
	# just dump everything we get from the xmpp server
	# if this doesn't work, we don't know how to handle errors anyway
	# and the xmpp server will disconnect us if we do something stupid
	while true
	do
		_xmpp_read 2
		ret=$?
		[ $ret -eq 1 ] && break
		[ $ret -gt 2 ] && _disconnect $ret
	done
	
	_xmpp_p "$stream_start"
	# again, just ignore the <stream:stream> answer
	local before=$(date +%s)
	local after=$before
	debug "throwing away everything from our input stream for the next 10 seconds"
	while [ "$(( $after - $before ))" -lt 10 ]
	do
		_xmpp_read 2
		ret=$?; [ $ret -gt 2 ] && _disconnect $ret
		after=$(date +%s)
	done
	
	_xmpp_p "$stream_bind"
	_xmpp_read
	ret=$?; [ $ret -gt 2 ] && _disconnect $ret
	local resp=$resp$result
	
	_xmpp_p "$stream_presence"
	
	while true
	do
		debug "Inside loop"
		_xmpp_read
		ret=$?; [ $ret -gt 2 ] && _disconnect $ret
		resp=$resp$result
		while [ ! -z "$resp" ]
		do
			_xmpp_treat "$resp" || break;
			resp=$result
		done
	done
	_disconnect 2
}


_start() {
	local jid=$1
	local resource=$2
	local login_pass=$3
	local ncat=$4
	local fifo_loop=$5
	local fifo_control=$6
	local fifo_reply=$7
	local output_eval=$8
	local calledWith=$9

	debug "Starting xmpp-client with jid: $jid/$resource.  ncat is $ncat.  Fifos: loop: $fifo_loop, command: $fifo_control, reply: $fifo_reply"

	# make the fifos
	for fifo in "$fifo_loop" "$fifo_control" "$fifo_reply"
	do
		local fifo_dir=$(dirname "$fifo")
		mkdir -p "$fifo_dir" 2> /dev/null > /dev/null
		mkfifo "$fifo"
	done

	# this goes into background and will stay alive
	(
		exec 3<>"$fifo_loop"
		exec 9<>"$fifo_reply"

		# after ncat closes (probably because disconnected) close fd 3 so that _xmpp will finish as well
		_xmpp "$jid" "$resource" "$login_pass" "$fifo_control" "$fifo_reply" <&3 | (sh -c "$ncat"; exec 3<&-) >&3
	) >/dev/null &
	# disconnect stdout so that command substitution does not block

	if [ "$output_eval" = "t" ]
	then
		echo -n "XMPP_SOCKET_CTRL=\"$fifo_control\";"
		echo -n "export XMPP_SOCKET_CTRL;"
		echo -n "XMPP_SOCKET_REPLY=\"$fifo_reply\";"
		echo -n "export XMPP_SOCKET_REPLY;"
		echo -n "XMPP_SOCKET_LOOP=\"$fifo_loop\";"
		echo "export XMPP_SOCKET_LOOP;"
		echo "# Whenever you want to communicate with this xmpp instance you have to provide"
		echo "# the following sockets, either by passing the arguments --fifo_control and --fifo_reply"
		echo "# or by setting the ENV variables XMPP_SOCKET_CTRL and XMPP_SOCKET_REPLY"
		echo "# Easiest way is to just copy paste and execute the next lines."
		echo "# (You can automate this the next time using eval: "
		echo -n '# eval `'; echo -n "$calledWith"; echo '`'
		echo "# )"
	fi
}

throwError() {
	echo "$2"
	echo
	echo
	printUsage
	exit $1
}

switchToControlMode() {
	printf '%s' "$control_mode_char" > "$fifo_loop"
}

IFS="$nl"

if [ "$cmd" = "$cmd_connect" ]
then
	# assume we should connect
	# verify all necessary information is provided
	errorMessage=""
	if [ "$jid" = "" ]
	then
		errorMessage="$errorMessage\njid not provided"
	fi
	if [ "$login_pass" = "" ]
	then
		errorMessage="$errorMessage\npassword not provided"
	fi
	if [ "$errorMessage" != "" ]
	then
		throwError 1 "$errorMessage"
	fi

	debug "Calling _start from $$"
	_start "$jid" "$resource" "$login_pass" "$ncat" "$fifo_loop" "$fifo_control" "$fifo_reply" "$output_eval" "$calledWith"
fi


if [ "$cmd" = "$cmd_message" ]
then
	_msg=
	debug "Message called with $argument1 and $argument2"
	# send a message
	# verify all necessary information is provided
	if [ "$argument2" = "" ]
	then
		throwError 2 "Destination or message not given"
	fi
	# send control_mode_char to loop fifo and message to control fifo
	switchToControlMode
	printf '%s\n' "$cmd" > "$fifo_control"
	# send destination to control pipe
	printf '%s\n' "$argument1" > "$fifo_control"
	for line in $argument2
	do
		debug "  Message line: $line"
		if [ "${line:0:1}" = "." ]
		then
			_msg="$_msg.$line$nl"
		else
			_msg="$_msg$line$nl"
		fi
	done
	# end message with .
	_msg="$_msg$nl.$nl"
	debug "Sending to fifo_control: ***$_msg***"
	printf '%s' "$_msg" > "$fifo_control"
	head -n 1 < "$fifo_reply"
fi

if [ "$cmd" = "$cmd_status" ]
then
	_status=
	debug "Status called with $argument1"
	# set status
	# verify all necessary information is provided
	if [ "$argument1" = "" ]
	then
		throwError 3 "Status not given!"
	fi
	# send control_mode_char to loop fifo and status to control fifo
	switchToControlMode
	printf '%s\n' "$cmd" > "$fifo_control"
	for line in $argument1
	do
		debug "  Status line: $line"
		if [ "${line:0:1}" = "." ]
		then
			_status="$_status.$line$nl"
		else
			_status="$_status$line$nl"
		fi
	done
	# end message with .
	_status="$_status$nl.$nl"
	debug "Sending to fifo_control: ***$_status***"
	printf '%s' "$_status" > "$fifo_control"
	head -n 1 < "$fifo_reply"
fi

if [ "$cmd" = "$cmd_msg_count" ]
then
	# output msg count
	switchToControlMode
	printf '%s\n' "$cmd" > "$fifo_control"
	head -n 1 < "$fifo_reply"
fi

if [ "$cmd" = "$cmd_next_msg" ]
then
	# output next msg
	switchToControlMode
	printf '%s\n' "$cmd" > "$fifo_control"
	while true
	do
		debug "read from reply (msg) ($$)"
		read -r line < "$fifo_reply"
		if [ "$line" = "." ]
		then
			break
		fi
		if [ "${line:0:1}" = "." ]
		then
			printf '%s\n' "${line:1}"
		else
			printf '%s\n' "$line"
		fi
	done
fi

if [ "$cmd" = "$cmd_gen_pass" ]
then
	echo -n "Please enter your username: "
	read username
	echo -n "Please enter your password (will be visible): "
	read password
	printf '\0%s\0%s' "$username" "$password" | base64
fi

if [ "$cmd" = "$cmd_disconnect" ]
then
	switchToControlMode
	printf '%s\n' "$cmd" > "$fifo_control"
fi

if [ "$cmd" = "" ]
then
	throwError -1 ""
fi

# FIXME
# need to go over exit states.  What if we get disconnected...
# also just waiting 10 seconds is not cool (when starting)

# process groups would be nicer, but openwrt router don't have the necessary executables
# we can however grep for environment variables and values in /proc/xxx/environ
# By exporting _XMPP_PROCESS_TAG we can find all child processes and kill them here.
# Thanks to stackoverflow (can't find the page any longer)
#_killall_tagged() {
#	local tag=$1
#	local pids=""
#
#	debug "Going to kill all processes which are tagged with: $_XMPP_PROCESS_TAG"
#	if [ "$tag" != "" ]
#	then
#		for pidpath in $(grep -la "_XMPP_PROCESS_TAG=$tag" /proc/*/environ 2> /dev/null)
#		do
#			local tagged_pid=$(echo $pidpath | sed 's!/proc/\([^/]*\)/.*!\1!')
#			if [ "$tagged_pid" = "self" ]
#			then
#				continue
#			else
#				debug "adding >>>$tagged_pid<<< to list of processes to be killed"
#				pids="$pids $tagged_pid"
#			fi
#		done
#		debug "kill $pids"
#		#kill $pids 2> /dev/null # FIX IFS!
#		echo $pids | xargs kill 2> /dev/null
#	fi
#}
#
#_get_random() {
#	local nbOfCharacters=$1
#	grep -m$nbOfCharacters -ao '[0-9]' /dev/urandom | tr -d '\n' | head -c $nbOfCharacters
#}
#
#	export _XMPP_PROCESS_TAG=$(_get_random 10)
#	debug "Calling _start from $$"
#	$0 --$cmd_start "$jid" "$resource" "$login_pass" "$ncat" "$fifo_loop" "$fifo_control" "$fifo_reply" "$output_eval" "$calledWith"
