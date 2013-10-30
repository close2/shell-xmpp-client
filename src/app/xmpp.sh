#!/bin/sh

_XMPP="$(dirname $0)/_xmpp.sh"
control_mode_char="$(printf '\a')"

# get debug_file from arguments _or_ ENV
# loop_fifo

calledWith="$0 $*"
debug() {
	[ -z "$debug_file" ] || printf '%s\n' "$1" >> "$debug_file"
}

debug "Called with: $calledWith"

# first parse env-variables
debug_file="$XMPP_DEBUG_FILE"
fifo_control=${XMPP_SOCKET_CTRL:-"/tmp/xmpp.$$/fifo.control"}
fifo_reply=${XMPP_SOCKET_REPLY:-"/tmp/xmpp.$$/fifo.reply"}
fifo_loop=${XMPP_SOCKET_LOOP:-"/tmp/xmpp.$$/fifo.loop"}

# then set some variables we probably never change
nl=$'\n'

IFS="$nl"

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
cmd_cancel_next_msg="cancel-next-msg"
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
arg_keep_fifos="keep-fifos"

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
	echo "	    --$arg_keep_fifos: don't delete fifos after disconnection"
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
keep_fifos="f"
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
		"--$arg_keep_fifos")
			keep_fifos="t"
			shift 1
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
		# no cmd_cancel_next_msg !
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

_xmpp_reply_p() {
	debug "To reply fifo: $1"
	if [ -z "$2" ]
	then
		printf '%s' "$1"
	else
		printf '%s\n' "$1"
	fi
}

received_messages=""
received_messages_count=0
message_received() {
	local from=$1
	local message=$2

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

autoEnterControlMode=
# return values: 0 means continue; 1 means disconnect
xmpp_control_mode() {
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
	if [ "$in_line" = "$cmd_cancel_next_msg" ]
	then
		debug "Canceling --$cmd_next_msg (this is actually a noop)"
		exec 20<&-
		_xmpp_reply_p "OK" "nl" > $fifo_reply
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
		send_msg "$to" "$txt"
		exec 20<&-
		_xmpp_reply_p "OK" "nl" > $fifo_reply
	fi
	if [ "$in_line" = "$cmd_status" ]
	then
		debug "read txt (status), read from fifo ($$)"
		_read_txt_block
		set_status "$txt"
		exec 20<&-
		_xmpp_reply_p "OK" "nl" > $fifo_reply
	fi
	debug "Returning from _xmpp_control_mode with 0"
	# close file-descriptor again (should already be closed!)
	exec 20<&-
	return 0;
}

### INSERT _XMPP LIB HERE ###
. "$_XMPP"

_start() {
	local jid=$1
	local resource=$2
	local login_pass=$3
	local ncat=$4
	local fifo_loop=$5 local fifo_control=$6
	local fifo_reply=$7
	local output_eval=$8
	local keep_fifos=$9
	local calledWith=$10

	debug "Starting xmpp-client with jid: $jid/$resource.  ncat is $ncat.  Fifos: loop: $fifo_loop, command: $fifo_control, reply: $fifo_reply"

	# make the fifos
	for fifo in "$fifo_loop" "$fifo_control" "$fifo_reply"
	do
		local fifo_dir=$(dirname "$fifo")
		mkdir -p "$fifo_dir" 2> /dev/null > /dev/null
		mkfifo "$fifo"
	done
	
	on_exit() {
		debug "on_exit (keep_fifos: $keep_fifos)"
		if [ "$keep_fifos" = "f" ]
		then
			for fifo in "$fifo_loop" "$fifo_control" "$fifo_reply"
			do
				debug "Deleting $fifo"
				local fifo_dir=$(dirname "$fifo")
				rm "$fifo"
				rmdir -p "$fifo_dir" 2> /dev/null > /dev/null
			done
		fi
	}

	# this goes into background and will stay alive
	(
		exec 3<>"$fifo_loop"
		exec 9<>"$fifo_reply"

		trap on_exit exit
		# after ncat closes (probably because disconnected) close fd 3 so that _xmpp will finish as well
		_xmpp "$jid" "$login_pass" "$resource" <&3 | (sh -c "$ncat"; exec 3<&-) >&3
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
		echo "# the following sockets, either by passing the arguments --$arg_fifo_loop, --$arg_fifo_reply and --$arg_fifo_control"
		echo "# or by setting the ENV variables XMP_SOCKET_LOOP, XMPP_SOCKET_CTRL and XMPP_SOCKET_REPLY"
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
	debug "Sending control_mode_char to fifo_loop"
	printf '%s' "$control_mode_char" > "$fifo_loop"
}


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
	_start "$jid" "$resource" "$login_pass" "$ncat" "$fifo_loop" "$fifo_control" "$fifo_reply" "$output_eval" "$keep_fifos" "$calledWith"
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
	head -n 1 < "$fifo_reply" > /dev/null
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
	head -n 1 < "$fifo_reply" > /dev/null
fi

if [ "$cmd" = "$cmd_msg_count" ]
then
	# output msg count
	switchToControlMode
	printf '%s\n' "$cmd" > "$fifo_control"
	head -n 1 < "$fifo_reply"
fi

cancel_next_msg() {
	switchToControlMode
	printf '%s\n' "$cmd_cancel_next_msg" > "$fifo_control"
	head -n 1 < "$fifo_reply" > /dev/null
}

if [ "$cmd" = "$cmd_next_msg" ]
then
	# output next msg
	switchToControlMode
	printf '%s\n' "$cmd" > "$fifo_control"
	# tell control_mode to not autoenter for next received message
	trap cancel_next_msg EXIT
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
	trap - EXIT
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

