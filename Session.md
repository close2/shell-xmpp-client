**[cl:~/shell-xmpp-client] $** ./xmpp.sh 



USAGE:
* Start connection:
	./xmpp.sh --connect --jid jid **[--resource console] {--pass password | --pass-file file} **[--ncat "ncat --ssl talk.google.com 5223"]
	Example: ./xmpp.sh --connect --jid bot@gmail.com --pass-file ~/.gmail_password
	  Possible optional arguments:
	    --no-eval-output: don't output eval commands
	    --fifo-loop, --fifo-reply, --fifo-control: specify names for fifos
	    --debug-file: debug output will be appended to this file (stderr would be /dev/fd/2)
* Get number of messages waiting for retrieval:
	./xmpp.sh --msg-count
	Example: ./xmpp.sh --msg-count
    Example Output:
      2
* Retrieve (and remove) next message:
	./xmpp.sh --next-msg
	Example: ./xmpp.sh --next-msg
    Example Output:
      somebody@gmail.com/resource1
      actual message
      possibly over multiple lines
* Send message:
	./xmpp.sh --msg to_jid txt
	Example: ./xmpp.sh --msg somebody@gmail.com "$(printf 'Hello\nnice to see you')"
* Set status:
	./xmpp.sh --set-status txt
	Example: ./xmpp.sh --set-status "bot is waiting"
* Disconnect:
  ./xmpp.sh --disconnect
* Generate password for either --pass or for --pass-file
	./xmpp.sh --generate-password
* Print this help:
	./xmpp.sh --help


**[cl:~/shell-xmpp-client] $** ./xmpp.sh --generate-password
Please enter your username: xmpp@delta64.com
Please enter your password (will be visible): fakePassword
AHhtcHBAZGVsdGE2NC5jb20AZmFrZVBhc3N3b3Jk
**[cl:~/shell-xmpp-client] $** printf "AHhtcHBAZGVsdGE2NC5jb20AZmFrZVBhc3N3b3Jk" > pass
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --connect --jid xmpp@delta64.com --pass-file pass
# Whenever you want to communicate with this xmpp instance you have to provide
# the following sockets, either by passing the arguments --fifo_control and --fifo_reply
# or by setting the ENV variables XMPP_SOCKET_CTRL and XMPP_SOCKET_REPLY
# Easiest way is to just copy paste and execute the next lines.
# (You can automate this the next time using eval: 
# eval `./xmpp.sh --connect --jid xmpp@delta64.com --pass-file pass`
# )
XMPP_SOCKET_CTRL="/tmp/xmpp.20544/fifo.control"
export XMPP_SOCKET_CTRL
XMPP_SOCKET_REPLY="/tmp/xmpp.20544/fifo.reply"
export XMPP_SOCKET_REPLY
XMPP_SOCKET_LOOP="/tmp/xmpp.20544/fifo.loop"
export XMPP_SOCKET_LOOP
**[cl:~/shell-xmpp-client] $** XMPP_SOCKET_CTRL="/tmp/xmpp.20544/fifo.control"
**[cl:~/shell-xmpp-client] $** export XMPP_SOCKET_CTRL
**[cl:~/shell-xmpp-client] $** XMPP_SOCKET_REPLY="/tmp/xmpp.20544/fifo.reply"
**[cl:~/shell-xmpp-client] $** export XMPP_SOCKET_REPLY
**[cl:~/shell-xmpp-client] $** XMPP_SOCKET_LOOP="/tmp/xmpp.20544/fifo.loop"
**[cl:~/shell-xmpp-client] $** export XMPP_SOCKET_LOOP
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --msg-count
0
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --msg c@delta64.com "hi there"
**[cl:~/shell-xmpp-client] $** ./xmpp.sh -msg-count
1
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --next-msg
c@delta64.com/gmail.CEFA6325
hi shell-xmpp-client!
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --msg c@delta64.com/gmail.CEFA6325 "hi there again"
**[cl:~/shell-xmpp-client] $** ./xmpp.sh -msg-count
0
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --next-msg
c@delta64.com/gmail.CEFA6325
that's a boring conversation
:)
**[cl:~/shell-xmpp-client] $** # --next-msg was blocking until the next message arrived!
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --set-status "Currently writing some doc for xmpp-shell-client"
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --next-msg
c@delta64.com/gmail.CEFA6325
I noticed you changed your Status:
»Christian's new status message - Currently writing some doc for xmpp-shell-client«
**[cl:~/shell-xmpp-client] $** ./xmpp.sh --disconnect

