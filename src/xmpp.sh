#!/bin/sh


xmpp() {

local jid=$1
local login_pass=$2

# create your abc@gmail.com, passwort xyz auth-text with: printf '\0abc\0xyz' | base64
# and store it in config.txt:  login_pass=AGFiYwB4eXo=
# also add jid=abc@gmail.com
# you may add an xmpp_resouce=console line as well
# eols of message/body text of the incoming stream have been replaced with this character:
# you can overwrite eol_replacement in the config file as well (only character not allowed is # !
local my_eol_repl=$(printf '\a')
local eol_replacement=${eol_replacement:-$my_eol_repl}
local xmpp_resouce=${xmpp_resouce:-"console"}

# escape eol_replacement for sed usage
# http://stackoverflow.com/questions/407523/escape-a-string-for-sed-search-pattern
# http://backreference.org/2009/12/09/using-shell-variables-in-sed/
local eol_replacement_search=$(printf '%s\n' "$eol_replacement" | sed 's/[][\.*/]/\\&/g; s/$$/\\&/; s/^^/\\&/')
local eol_replacement_repl=$(printf '%s\n' "$eol_replacement" | sed 's/[\&/]/\\&/g')

local login_domain=${jid#*@}
local stream_start="<stream:stream to=\"$login_domain\" version=\"1.0\" xmlns=\"jabber:client\" xmlns:stream=\"http://etherx.jabber.org/streams\">"
local stream_auth="<auth xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\" mechanism=\"PLAIN\">$login_pass</auth>"
local stream_bind="<iq id=\"bind1\" from=\"$jid\" type=\"set\"><bind xmlns=\"urn:ietf:params:xml:ns:xmpp-bind\"><resource>$xmpp_resouce</resource></bind></iq>"
local stream_presence='<presence/>'
local stream_iq_error='<iq type="error" id="%s"><service-unavailable/></iq>'
local stream_status='<presence><status>%s</status></presence>'
local stream_send_msg='<message to="%s" type="chat"><body>%s</body></message>'
local stream_end='</stream:stream>'

local nl='
'

if ! type debug &>/dev/null
then
	debug () {
		true
	}
fi

_xmpp_p() {
	debug "$1"
	printf '%s' "$1"
}

_xmpp_p2() {
	printf '%s' "$1"
}

local result=""
_xmpp_nb_read() {
	local allow_empty=$1
	local input=
	local before_loop=$(date +%s)
	local in_line=
	while true
	do
		unset in_line

		local ifs_backup=$IFS
		IFS=

		local before=$(date +%s)
		read -r -t 2 in_line
		local diff=$(( $(date +%s) - $before ))
		
		IFS=$ifs_backup

		if [ "$in_line" != "" ]
		then
			debug "$in_line"
		fi

		if [ -z "$input" ] && [ -z "$in_line" ] && [ $diff -lt 1 ]
		then
			debug "EMPTY INPUT"
			debug $before
			debug $diff
			# if our in_line is empty, but read didn't take 2 seconds
			# stdin returned an EOF → exit
			# Note that we can't use the return value of read because ash returns 1 in both cases
			exit 1
		fi
		
		# never zero unless timeout or EOF  (see sed at the top of this file)
		if [ -z "$in_line" ]
		then
			if [ ! -z "$input" ] || [ ! -z "$allow_empty" ]
			then
				break
			fi
		else
			input=$input$in_line
			# prevent that we never leave this loop if somebody (could be even the xmpp-server)
			# sends us something every 2 seconds
			local diff_loop=$(( $(date +%s) - $before_loop ))
			[ "$diff_loop" -gt 10 ] && break
		fi
        done
	result=$input
	if [ "$input" != "" ]
	then
		debug "Read: $input"
		return 0
	fi
	return 1
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
			type message_received &>/dev/null &&
			message_received "$message_from" "$message_body"
		fi
		result=$result_rest
		return 0
	fi
	result=$result_rest
}

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

set_status() {
	debug "Setting status"
	local status_msg=$1
	_xmpp_escape "$status_msg"
	local status_stanza=$(printf "$stream_status" "$escaped")
	_xmpp_p "$status_stanza"
}

send_msg() {
	debug "Sending message"
	_xmpp_escape "$1"
	local to=$escaped
	_xmpp_escape "$2"
	local message=$escaped
	local msg_stanza=$(printf "$stream_send_msg" "$to" "$message")
	_xmpp_p "$msg_stanza"
}

### MAIN ###
# start stream
_xmpp_p "$stream_start"
_xmpp_nb_read
_xmpp_p "$stream_auth"
# just dump everything we get from the xmpp server
# if this doesn't work, we don't know how to handle errors anyway
# and the xmpp server will disconnect us if we do something stupid
while true
do
	_xmpp_nb_read "allow_empty" || break
done

_xmpp_p "$stream_start"
# again, just ignore the <stream:stream> answer
local before=$(date +%s)
local after=$before
debug "throwing away everything from our input stream for the next 10 seconds"
while [ "$(( $after - $before ))" -lt 10 ]
do
	_xmpp_nb_read "allow_empty"
	after=$(date +%s)
done

_xmpp_p "$stream_bind"
_xmpp_nb_read
local resp=$resp$result

_xmpp_p "$stream_presence"
_xmpp_nb_read
resp=$resp$result

while true
do
	_xmpp_nb_read "allow_empty"
	resp=$resp$result
	while [ ! -z "$resp" ]
	do
		_xmpp_treat "$resp" || break;
		resp=$result
	done

	if type poll &>/dev/null
	then
		poll || break
	fi
done

_xmpp_p "$stream_end"

}


_xmpp_prepare() {
	local my_eol_repl=$(printf '\a')
	eol_replacement=${eol_replacement:-$my_eol_repl}
	IFS=
	local char_in=
	while true
	do
		read -r -n1 char_in || return 1
		if [ -z "$char_in" ]
		then
			printf '%s' "$eol_replacement"
			continue
		fi
		if [ "$char_in" = ">" ]
		then
			printf '>\n'
			continue
		fi
		printf '%s' "$char_in"
	done
}

fifo_ctrl() {
	fifo_to_xmpp=${fifo_to_xmpp:-"/tmp/fifo_to_xmpp.$$"}
	fifo_from_xmpp=${fifo_from_xmpp:-"/tmp/fifo_from_xmpp.$$"}
	mkfifo "$fifo_to_xmpp"
	mkfifo "$fifo_from_xmpp"
	exec 5<>"$fifo_to_xmpp"
	exec 6<>"$fifo_from_xmpp"

	message_received() {
		local my_eol_repl=$(printf '\a')
		local eol_replacement=${eol_replacement:-$my_eol_repl}
		local eol_replacement_search=$(printf '%s\n' "$eol_replacement" | sed 's/[][\.*/]/\\&/g; s/$$/\\&/; s/^^/\\&/')
		local eol_replacement_repl=$(printf '%s\n' "$eol_replacement" | sed 's/[\&/]/\\&/g')

		local from=$1
		local message=$2

		debug "Sending to fifo. From: $from, Message: $message"
		# thanks http://stackoverflow.com/questions/1251999/sed-how-can-i-replace-a-newline-n
		local message_eol_repl=$(printf '%s' "$message" | sed ":a;N;\$!ba;s/\n/$eol_replacement_repl/g")
		printf '%s\n%s\n' "$from" "$message_eol_repl" >&6
	}
	
	poll() {
		local my_eol_repl=$(printf '\a')
		local eol_replacement=${eol_replacement:-$my_eol_repl}
		local eol_replacement_search=$(printf '%s\n' "$eol_replacement" | sed 's/[][\.*/]/\\&/g; s/$$/\\&/; s/^^/\\&/')
		local eol_replacement_repl=$(printf '%s\n' "$eol_replacement" | sed 's/[\&/]/\\&/g')

		local command=
		read -r -t 1 fifo_in <&5
		[ -z "$command" ] || debug "Read $command from fifo"

		case "$command" in
		END*)
			debug "end xmpp client"
			return 1
		;;
		STATUS*)
			# just assume it is followed by eol_replacement:
			local status_start=$(( 6 + ${#eol_replacement} ))
			local status_msg=""
			[ $status_start -lt ${#command} ] && status_msg=${command:$status_start}
			debug "status-message, status: $status_msg"
			set_status "$status_msg"
			return 0
		;;
		MESSAGE*)
			# just assume it is followed by eol_replacement:
			local to_and_txt_start=$(( 7 + ${#eol_replacement} ))
			[ $to_and_txt_start -lt ${#command} ] || return 1
			local to_and_txt=${command:$to_and_txt_start}
			to_and_txt=$(p2 "$to_and_txt" | sed "s/$eol_replacement_search/\n/g")
			local command_message_to=
	
			local bifs=$IFS
			for i in $to_and_txt
			do
				command_message_to=$i
				break
			done
			IFS=$bifs
	
			# +1 already added for \n
			local to_length=$(( ${#command_message_to} + 1 ))
			# could probably be even higher than 3
			[ $to_length -gt 3 ] || return 2
			
			local command_message_txt=${to_and_txt:$to_length}
			
			debug "message to send, to: $command_message_to"
			debug "message is: $command_message_txt"
			send_msg "$command_message_to" "$command_message_txt"
			return 0
		;;
		esac
	
		debug "unknown message"
		return 0
	}
	
}

start_xmpp() {
	local jid=$1
	local login_pass=$2
	local ncat=${3:-"ncat --ssl talk.google.com 5223"}

	debug "Starting xmpp-client"
	local loop_fifo="/tmp/loop.fifo.$$"
	(
		mkfifo "$loop_fifo"
		exec 3<>"$loop_fifo"
		rm "$loop_fifo"
		$ncat <&3 | _xmpp_prepare | xmpp "$jid" "$login_pass" >&3
	)
}

