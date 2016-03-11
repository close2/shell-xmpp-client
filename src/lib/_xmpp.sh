#!/bin/bash

# Bali notes:
# rename _xmpp_p2 to p() (or similar).
# rename result to received_data
# create wrapper function for IFS (which sets and resets IFS)
# reg expr in _xmpp_split_input are missing some [[:space:]]
# use error_iq instead of result for _xmpp_build_error_iq()
# rename _xmpp_treat to _xmpp_process (all treat should become process)
# don't use _xmpp_p (p) unless we send to server.  Search for $(_xmpp_p 
# in _process_input convert stop_on to uppercase (tr a..z A..Z)

# need the following variables set:
# jid: example xmpp@delta64.com
# login_pass: build it using printf '\0%s\0%s' "$username" "$password" | base64
# resource: if not provided console is used
# ncat: if not provided "ncat --ssl talk.google.com 5223" is used

# interact by providing the following functions:
#
# message_received
# xmpp_control_mode which is entered whenever the control_mode_char (\a) is sent to the loop-fifo
#   in xmpp_control_mode
# send_msg to body
# set_status status_text
# disconnect

# _xmpp
#   processes the incoming stream.
#   If it receives an \a character interrupts and switches to control-mode by calling xmpp_control_mode function
#   In control mode _xmpp should never block and control!
#
_xmpp() {
	local jid=$1
	local login_pass=$2
	local resource=${3:-"console"}

	local nl=$'\n'

	IFS="$nl"

	# this is the character which must be inserted in the loop fifo in order to enter control_mode
	local control_mode_char="$(printf '\a')"

	# escape eol_replacement for sed usage
	# http://stackoverflow.com/questions/407523/escape-a-string-for-sed-search-pattern
	# http://backreference.org/2009/12/09/using-shell-variables-in-sed/
	local eol_replacement="$(printf '\a')"
	local eol_replacement_search=$(printf '%s\n' "$eol_replacement" | sed 's/[][\.*/]/\\&/g; s/$$/\\&/; s/^^/\\&/')
	local eol_replacement_repl=$(printf '%s\n' "$eol_replacement" | sed 's/[\&/]/\\&/g')
	
	local login_domain=${jid#*@}
	# commands we send to the xmpp server:
	local stream_start="<stream:stream to=\"$login_domain\" version=\"1.0\" xmlns=\"jabber:client\" xmlns:stream=\"http://etherx.jabber.org/streams\">"
	local stream_auth="<auth xmlns=\"urn:ietf:params:xml:ns:xmpp-sasl\" mechanism=\"PLAIN\">$login_pass</auth>"
	local stream_bind="<iq id=\"bind1\" from=\"$jid\" type=\"set\"><bind xmlns=\"urn:ietf:params:xml:ns:xmpp-bind\"><resource>$resource</resource></bind></iq>"
	local stream_presence='<presence/>'
	local stream_iq_error='<iq type="error" id="%s"><service-unavailable/></iq>'
	local stream_status='<presence><status>%s</status></presence>'
	local stream_send_msg='<message to="%s" type="chat"><body>%s</body></message>'
	local stream_end='</stream:stream>'

	_xmpp_p() {
		debug "$1"
		printf '%s' "$1"
	}

	_xmpp_p2() {
		printf '%s' "$1"
	}

	if ! type debug > /dev/null 2>&1
	then
		debug() {
			# don't do anything
			true
		}
	fi

	local escaped=
	_xmpp_escape() {
		local input=$1
		#                                        & → &amp;         " → &quot;         ' → &apos;          < → &lt;         > → &gt;
		escaped=$(_xmpp_p2 "$input" | sed -e 's#\&#\&amp;#g' -e 's#"#\&quot;#g' -e "s#'#\\&apos;#g" -e 's#<#\&lt;#g' -e 's#>#\&gt;#g')
	}
	
	local unescaped=
	_xmpp_unescape() {
		local input=$1
		unescaped=$(_xmpp_p2 "$input" | sed -e 's#\&quot;#"#g' -e "s#\\&apos;#'#g" -e 's#\&lt;#<#g' -e 's#\&gt;#>#g' -e 's#\&amp;#&#g')
	}
	
	#   0: data received / available
	#   100: _xmpp_control told us to disconnect
	#   101: nothing received, other side probably disconnected
	local result=""
	_xmpp_read() {
		local ifs_backup="$IFS"
		IFS=
	
		local char_in=

		[ "$autoEnterControlMode" = "" ] || xmpp_control_mode "$autoEnterControlMode"

		while true
		do
			if ! read -r -n1 char_in
			then
				debug "Didn't read anything.  Loop fifo apparently 'died'."
				IFS="$ifs_backup"
				return 101
			fi
	
			if [ "$char_in" = "$control_mode_char" ]
			then
				autoEnterControlMode=
				if ! xmpp_control_mode
				then
					debug "xmpp_control_mode told us to disconnect, returning with 100"
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
		local xml_name=$(expr match "$input" '[^<]*<[[:space:]]*\([a-zA-Z0-9_:]*\)')
	
		result_xml_name=
		result_xml=
		result_rest=
	
		if [ ${#xml_name} -eq 0 ]
		then
			debug "could not extract XML name"
			return 1
		fi
	
		# let's try <abc ... /> first
		local xml_1=$(expr match "$input" '[^<]*\(<[[:space:]]*[a-zA-Z0-9_:]*\([^>]\)*/>\).*')
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

		# finally try <stream:stream> which doesn't have an end
		local xml_stream=$(expr match "$input" '[^<]*\(<[[:space:]]*[sS][tT][rR][eE][aA][mM][[:space:]]*:[[:space:]]*[sS][tT][rR][eE][aA][mM]\([^>]\)*>\).*')
		if [ ${#xml_stream} -gt 0 ]
		then
			debug "stream:stream found"
			debug "${#xml_stream}"
			local xml_2=${input:${#xml_stream}}
			result_xml_name="stream:stream"
			result_xml=$xml_stream
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
		local input=$1
		debug "processing: $input"
	
		_xmpp_split_input "$input" || return 1
	
		debug "split-input:${nl}xml-name: $result_xml_name${nl}xml: $result_xml${nl}rest: $result_rest"
	
		local xml_name=$(_xmpp_p2 "$result_xml_name" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
		result_xml_name=$xml_name
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
			if _xmpp_analyze_message "$result_xml" && type message_received > /dev/null 2>&1
			then
				message_received "$message_from" "$message_body"
			fi
			result=$result_rest
			return 0
		fi
		result=$result_rest
		return 0
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

	disconnect() {
		_xmpp_p "$stream_end"
		exit $1
	}

	local unprocessed_input
	_process_input() {
		local stop_on=$1
		local ret=0
		while true
		do
			debug "Inside process input loop (waiting for $stop_on)"
			_xmpp_read
			ret=$?; [ $ret -gt 2 ] && disconnect $ret
			unprocessed_input=$unprocessed_input$result
			while [ ! -z "$unprocessed_input" ]
			do
				_xmpp_treat "$unprocessed_input" || break;
				unprocessed_input=$result
				debug "Just processed xml entity: $result_xml_name"
				[ "$stop_on" != "" ] && [ "$result_xml_name" = "$stop_on" ] && return 0;
			done
		done
	}


	### MAIN ###
	local ret
	# start stream
	debug "=== Sending stream_start ==="
	_xmpp_p "$stream_start"
	_process_input "STREAM:STREAM"
	_process_input "STREAM:FEATURES"
	
	debug "=== Sending stream_auth ==="
	_xmpp_p "$stream_auth"
	
	debug "=== Sending stream_start ==="
	_xmpp_p "$stream_start"

	# and again throw away the stream:stream
	_process_input "STREAM:STREAM"
	
	debug "=== Sending stream_bind ==="
	_xmpp_p "$stream_bind"
	# we require an iq result (let's hope the iq we read is the correct one)
	_process_input "IQ"
	
	_xmpp_p "$stream_presence"

	_process_input
	disconnect 2
}

