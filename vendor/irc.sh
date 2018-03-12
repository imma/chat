#!/bin/bash

source numeric_commands.sh

# irc_tokenise "$line"
# Takes a line of IRC protocol, and splits it up.
# Sets $IRC_PREFIX (empty if the line has no prefix), $IRC_COMMAND, and
# $IRC_PARAMS.  $IRC_PARAMS is an array variable.
irc_tokenise () {
  # Clear out any values from previous calls.
  unset -v IRC_PREFIX IRC_COMMAND IRC_PARAMS
  declare -g -u IRC_COMMAND

  # IRC lines are terminated with \r\n, so strip that off.
  local LINE="${*%$'\r\n'}"
  # If something else has eaten the trailing newline, make sure we remove
  # a trailing \r too.
  LINE="${LINE%$'\r'}"

  # This means we lose consecutive spaces or tab characters that happened to be
  # in the line... but who cares.
  set -- $LINE
  
  # If the line starts with ":" then the first word is the prefix.
  if [[ "$1" == ':'* ]]; then
    IRC_PREFIX=${1#:}
    shift
  else
    IRC_PREFIX=""
  fi

  # The next word is always the command.
  IRC_COMMAND="$1"
  shift

  # Now for the parameters...
  local index=0
  while (( $# > 0 )); do
    # If this parameter begins with a colon...
    if [[ "$1" == ':'* ]]; then
      # ...all remaining words are part of this parameter.
      IRC_PARAMS[$index]="$*"
      # ...but we need to strip the colon off the front.
      IRC_PARAMS[$index]="${IRC_PARAMS[$index]#:}"
      break

    # Otherwise, this is just another parameter.
    else
      IRC_PARAMS[$index]=$1
      index=$(($index + 1))
      shift
    fi
  done

  # No need to export IRC_PARAMS, since it's an array variable and bash won't
  # export it anyway.
  export IRC_PREFIX IRC_COMMAND
}

# irc_dequote
# Performs the "low-level dequoting" described by the CTCP specification.
# Processes $IRC_PARAMS, assuming irc_tokenise has already been called.
irc_dequote () {
  declare -a dequoted

  local index=0
  for p in "${IRC_PARAMS[@]}"; do
    # "If the character following M-QUOTE is not any of the listed characters,
    # that is an error, so drop the M-QUOTE character from the message..."
    p=$(echo -n "$p" | sed -e $'s/\\([^\020]\\)\\([^\020nr]\\)/\\1\\2/g')

    # The CTCP spec requires that ^P be quoted as ^P^P, but that makes
    # unescaping problematic. After the previous command, we know that there's no
    # bare ^P characters sitting around in front of innocent bystanders, so we
    # can temporarily change the ^P quote char to something else.
    p=${p//$'\020\020'/$'\020p'}

    # Now we can easily handle all the de-quoting.
    p=${p//$'\020r'/$'\r'}
    p=${p//$'\020n'/$'\n'}
    p=${p//$'\020p'/$'\020'}

    # The CTCP spec requires that ^P0 be de-quoted to \0, but there's no way to
    # store \0 in an environment variable, so let's not even bother trying.

    dequoted[$index]="$p"
    index=$(($index + 1))
  done

  IRC_PARAMS=("${dequoted[@]}")
}

# irc_cmdparse
# Processes the output of irc_tokenise, parsing certain common commands and
# putting useful parameters into separate environment variables so that they
# can be accessed by things other than bash.
# Reads the environment variables set by irc_tokenise and sets $IRC_SENDER,
# $IRC_CHANNEL, $IRC_TEXT, $IRC_BOTID and $IRC_BOTNICK when appropriate.
irc_cmdparse () {
  unset -v IRC_SENDER IRC_CHANNEL IRC_TEXT

  # The prefix, if any, generally represents the sender of the message. Grab
  # the nick at the front of the sender ID.
  IRC_SENDER=${IRC_PREFIX%%!*}

  case $IRC_COMMAND in
    $RPL_WELCOME)
      # Our nick is parameter 0
      IRC_BOTNICK="${IRC_PARAMS[0]}"
      # The welcome message is parameter 1.
      IRC_TEXT="${IRC_PARAMS[1]}"
      # Ask the server what our full ID is.
      printf "WHOIS %s\n" "$IRC_BOTNICK"
      ;;
    $RPL_WHOISUSER)
      # If this WHOIS response is describing us...
      if [[ ${IRC_PARAMS[0]} == ${IRC_PARAMS[1]} ]]; then
        # ...set our nick variables accordingly.
        IRC_BOTNICK=${IRC_PARAMS[1]}
        IRC_BOTID="${IRC_PARAMS[1]}!${IRC_PARAMS[2]}@${IRC_PARAMS[3]}"
      fi
      ;;
    PART)
      IRC_CHANNEL=${IRC_PARAMS[0]}
      ;;
    TOPIC)
      IRC_CHANNEL=${IRC_PARAMS[0]}
      IRC_TEXT=${IRC_PARAMS[1]}
      ;;
    MODE)
      # Make a local copy of $IRC_PARAMS so we can mess around without damaging the
      # original.
      local params=("${IRC_PARAMS[@]}")

      IRC_CHANNEL=${params[0]}
      unset params[0]

      # The mode and the targets are the rest of the parameters; since we don't
      # have a better way to represent such structured information, bung it in
      # a string and let the user sort it out.
      IRC_TEXT="${params[*]}"
      ;;
    PRIVMSG|NOTICE)
      # If the destination starts with a channel sigil...
      if [[ ${IRC_PARAMS[0]} == [#\&+\!]* ]]
      then
        # ...the response should go to the same channel.
        IRC_CHANNEL=${IRC_PARAMS[0]}
      else
        # ...otherwise, the response should go to the sender.
        IRC_CHANNEL=$IRC_SENDER
      fi
      IRC_TEXT=${IRC_PARAMS[1]}
      ;;
    JOIN)
      IRC_CHANNEL=${IRC_PARAMS[0]}
      IRC_TEXT=$IRC_CHANNEL
      ;;
    INVITE)
      IRC_CHANNEL=${IRC_PARAMS[1]}
      ;;
    NICK)
      IRC_TEXT=${IRC_PARAMS[0]}
      if [[ $IRC_PREFIX == $IRC_BOTID ]]; then
        IRC_BOTNICK="${IRC_PARAMS[0]}"
        IRC_BOTID="${IRC_PARAMS[0]}!${IRC_PREFIX#*!}"
      fi
      ;;
  esac

  export IRC_SENDER IRC_CHANNEL IRC_TEXT IRC_BOTID IRC_BOTNICK
}

# irc_ctcpparse
# Extract CTCP commands embedded in a PRIVMSG or NOTICE. Examines the output of
# irc_cmdparse and changes $IRC_COMMAND and $IRC_TEXT if appropriate.
irc_ctcpparse () {
  # CTCP commands can only ride in the payload of PRIVMSG and NOTICE messages.
  if [[ "$IRC_COMMAND" != "PRIVMSG" && "$IRC_COMMAND" != "NOTICE" ]]; then
    return
  fi

  # The CTCP spec suggests that multiple CTCP commands can be placed in the
  # payload of a PRIVMSG or NOTICE, but I don't know of any clients that would
  # actually send such a thing. For our purposes, we only care if the entire
  # payload is a CTCP message.
  if [[ "$IRC_TEXT" != $'\001'*$'\001' ]]; then
    return
  fi

  # The CTCP command is everything from the initial ^A up until the first space.
  local newCommand
  newCommand=${IRC_TEXT#$'\001'}
  newCommand=${newCommand%%[$'\001 ']*}

  if [[ "$IRC_COMMAND" == "PRIVMSG" ]]; then
    # PRIVMSG is used to indicate a CTCP request.
    IRC_COMMAND="${newCommand}_REQ"
  else
    # NOTICE is used to indicate a CTCP response.
    IRC_COMMAND="${newCommand}_RSP"
  fi

  # The CTCP payload is everything from after the first space (if any) up until the next ^A.
  IRC_TEXT=${IRC_TEXT#* }
  IRC_TEXT=${IRC_TEXT%%$'\001'*}

  # "If an X-QUOTE is seen with a character following it other than the ones
  # above, that is an error and the X-QUOTE character should be dropped."
  IRC_TEXT=$(echo -n "$IRC_TEXT" | sed -e 's/\([^\\]\)\\\([^\\a]\)/\1\2/g')

  # The CTCP spec requires that \ be quoted as \\, but that makes unescaping
  # problematic. After the previous command, we know that there's no bare \
  # characters sitting around in front of innocent bystanders, so we can
  # temporarily change the \ quote char to something else.
  IRC_TEXT=${IRC_TEXT//'\\'/'\b'}

  # Now we can easily handle all the de-quoting.
  IRC_TEXT=${IRC_TEXT//'\a'/$'\001'}
  IRC_TEXT=${IRC_TEXT//'\b'/'\'}
}

# irc_parse "$line"
# High-level IRC parsing. Pass each line you receive from the IRC server to
# this function, and we'll pull out the most important bits and put them into
# handy environment variables for you.
irc_parse () {
  irc_tokenise "$1"
  irc_dequote
  irc_cmdparse
  irc_ctcpparse
}

# irc_ping
# Relies on the $IRC_COMMAND variable from the irc_parse function
# The only bit of protocol that is essential for maintaining your
# connection to an IRC server is the timely response to ping commands.
# This function handles it, and returns success iff it responded to a PING
# command.
# You are recommended to use it in your bot like so:
# while read i; do
#   irc_parse
#   irc_ping && continue
#   ...
# done
irc_ping () {
  if [[ $IRC_COMMAND == "PING" ]]; then
    echo "PONG $IRC_PARAMS"
    return 0
  fi
  return 1
}

# _wrapwidth <prefix> <suffix>
# Calculates the maximum payload size for an IRC message that starts with
# $prefix and ends with $suffix. We assume the IRC server will prepend
# $IRC_BOTID and a single space, and normalise the line-terminator to CRLF.
_wrapwidth () {
  echo $(( 512 - ${#IRC_BOTID} - 1 - ${#1} - ${#2} - 2 ))
}

# _wrapmsg <prefix> <suffix> < [FILE]
# Reads a message payload from FILE, splits it over multiple lines, and
# attaches $prefix and $suffix to each one. The resulting lines are under the
# IRC limit of 512 characters, even after the server has attached $IRC_BOTID
# and CRLF.
_wrapmsg () {
  local prefix=$1
  local suffix=$2
  local width=$(_wrapwidth "$prefix" "$suffix")

  fold --width="$width" --spaces --bytes | while read -r line; do
    printf "%s%s%s\n" "$prefix" "$line" "$suffix"
  done
}

# _chopmsg <prefix> <suffix> < [FILE]
# Reads a message payload from FILE, truncates it and attaches $prefix and
# $suffix. The result should fit within the IRC limit of 512 characters, even
# after the server has attached $IRC_BOTID and CRLF.
_chopmsg () {
  _wrapmsg "$1" "$2" | head -n 1
}

# irc_enquote < [FILE] > [FILE]
# Reads a message from stdin, quotes problematic characters then writes out the
# result. This is what the CTCP spec calls "mid-level" quoting.
irc_enquote () {
  sed -n -e '
    # The first line goes straight to hold space.
    1 h

    # Every subsequent line gets appended to hold space.
    2,$ H

    # When we get to the last line...
    $ {
      # Move the whole blob back to pattern space.
      x

      # Escape all the ^Ps.
      s///g

      # Escape all the (embedded) newlines.
      s/\n/n/g

      # Escape all the carriage returns.
      s/\r/r/g

      # ...and print out the result.
      p
    }
  '
}

# irc_ctcpmsg [-m] <channel> <command> [<text>]
# Sends a CTCP $command request or reply to $channel, with payload $text.
# By default, command will be a reply unless "-m" is supplied, in which case it
# will be a request. If $text is not supplied, only the command will be sent.
irc_ctcpmsg () {
  local command="NOTICE"
  local marker=$'\001'
  if [[ $1 == '-m' ]]; then
    shift
    command="PRIVMSG"
  fi
  echo "$3" |
    sed -e 's/\\/\\\\/g' -e $'s/\001/\\\\a/g' |
    irc_enquote |
    _chopmsg "$command $1 :$marker$2 " "$marker"
}

# irc_msg [-m] <channel> <text> > [FILE]
# Print a PRIVMSG command on stdout, wrapped to fit the server response size
# limit of 512 bytes.
# By default it sends a NOTICE (which other bots are required to ignore) but
# the -m flag makes it use PRIVMSG (to seem more like a real person)
irc_msg () {
  local command="NOTICE $1 :"
  if [[ $1 == '-m' ]]; then
    shift
    command="PRIVMSG $1 :"
  fi
  echo "$2" | irc_enquote | _wrapmsg "$command" ""
}

# irc_action <channel> <text>
# Print an ACTION command on stdout, wrapped to fit the server response size
# limit of 512 bytes.
irc_action () {
  irc_ctcpmsg -m "$1" "ACTION" "$2"
}

# irc_respond [-m] < [FILE]
# Reads a payload from FILE, wraps it to multiple lines, formats it as a NOTICE
# or (if "-m" is supplied) PRIVMSG, and sends it to $IRC_CHANNEL. If the
# formatted payload contains more than 5 lines and $IRC_CHANNEL is an actual
# channel, instead of sending the entire thing to the channel, it will send it
# as a sequence of private messages to the sender, and send a "message too
# long, responding privately" message to the channel.
irc_respond () {
  local command="NOTICE"
  if [[ "$1" == '-m' ]]; then
    shift
    command="PRIVMSG"
  fi

  local origmsg=$(mktemp)
  cat > "$origmsg"

  local response=$(mktemp)
  cat "$origmsg" | irc_enquote | _wrapmsg "$command $IRC_CHANNEL :" "" > "$response"

  local responseLines=$(wc -l "$response" | cut -d" " -f1)

  # If it's a short message, or if we're responding directly to the sender
  # anyway, just send it.
  if [[ "$responseLines" -lt 5 || "$IRC_CHANNEL" == "$IRC_SENDER" ]]; then
    cat "$response"

  # It's a long message, so send it privately and leave a note in the channel.
  else
    irc_msg "$IRC_CHANNEL" "Response too long, sending privately."
    cat "$origmsg" | irc_enquote | _wrapmsg "$command $IRC_SENDER :" ""
  fi
}

# irc_dispatch <command> <argument>
# Relies on the $IRC_CHANNEL variable from the irc_parse function
# Runs <command> with a time limit of five seconds, and sends the output to 
# the same channel (or private user conversation) as one NOTICE per line
# (though long NOTICEs will be split).
irc_dispatch () {
  timeout 5 $1 $2 | while read message; do
    irc_msg $IRC_CHANNEL "$message"
  done
}
