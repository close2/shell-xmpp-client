#!/bin/sh

_XMPP="$(dirname $0)/_xmpp.sh"

# need the following variables set:
# jid: example xmpp@delta64.com
# login_pass: build it using printf '\0%s\0%s' "$username" "$password" | base64
# resource: if not provided console is used
# ncat: if not provided "ncat --ssl talk.google.com 5223" is used

### INSERT _XMPP LIB HERE ###
. "$_XMPP"

(
	ncat=${ncat:-"ncat --ssl talk.google.com 5223"}

        myRandom="$(sed 's/[^1-9]//g;' < /dev/urandom | tr '\n' '0' | head -c 20)"
        tmpFifo="/tmp/$myRandom.fifo"

	controlModeEvery=${control_mode_every:-10}

        mkfifo "$tmpFifo"
        exec 3<>"$tmpFifo"
        rm "$tmpFifo"

	if [ "$controlModeEvery" -gt 0 ]
	then
		# enter control mode every 10 seconds by sending the control_mode_char (\a)
	        (while true; do sleep $controlModeEvery; printf '\a' >&3; done) &
	        trap "kill $!" EXIT
	fi

	_xmpp "$jid" "$login_pass" "$resource" <&3 | (sh -c "$ncat"; exec 3<&-) >&3
)

