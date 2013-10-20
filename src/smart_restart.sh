#!/bin/sh

start_delay=5
max_delay=600

min_success_duration=300

last_start=$(date +%s)

next_delay=$start_delay
while true;
do
        before=$(date +%s)
        "$@"
        after=$(date +%s)
        runtime=$(( $after - $before ))
        [ $runtime -ge $min_success_duration ] && next_delay=$start_delay
        sleep $next_delay
        next_delay=$(( $next_delay + $next_delay ))
        [ $next_delay -gt $max_delay ] && next_delay=$max_delay
done
