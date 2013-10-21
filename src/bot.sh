#!/bin/bash

nl='
'

IFS="$nl"

declare -i count=0

while true
do
	incoming=$(./xmpp.sh --next-msg)
	from=
	message=
        for line in $incoming
        do
		if [ "$from" = "" ]
		then
			from="$line"
		else
			message="$message$nl$line"
		fi
        done
	echo "From: $from"
	echo "Message: $message"

	./xmpp.sh --msg "$from" "I can say that too!:$nl$message"

	sleep 3
	count=$count+1
	./xmpp.sh --set-status "I have replied to $count messages!"
done
