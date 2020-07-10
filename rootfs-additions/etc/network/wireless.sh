#!/usr/bin/env ash

# Copyright (c) 2018, Laird Connectivity
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
# OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.
#
# contact: support@lairdconnect.com

# /etc/network/wireless.sh - driver-&-firmware configuration for wb45n/wb50n
# 20120520/20180522

WIFI_PREFIX=wlan                              ## iface to be enumerated
WIFI_DRIVER=ath6kl_sdio                       ## device driver "name"

WIFI_PROFILES=/etc/summit/profiles.conf       ## sdc_cli profiles.conf

## monitor, supplicant and cli - comment out to disable . . .
EVENT_MON=/usr/bin/event_mon
SDC_SUPP=/usr/sbin/sdcsupp
SDC_CLI=/usr/bin/sdc_cli

## supplicant options
WIFI_80211=-Dnl80211                          ## supplicant driver nl80211

wifi_config() {
  # ensure that the profiles.conf file exists and is not zero-length
  # avoids issues while loading drivers and starting the supplicant
  [ ! -s "$WIFI_PROFILES" -a -x "$SDC_CLI" ] \
  && { msg re-generating $WIFI_PROFILES; rm -f $WIFI_PROFILES; $SDC_CLI quit; }

  return 0
}

wifi_set_dev() {
  ip link set dev $WIFI_DEV $1 2>&1 #/dev/null
}

msg() {
  echo "$@"
} 2>/dev/null

wifi_status() {
  echo -e "Modules loaded and size:"
  grep -s -e "${WIFI_DRIVER%%_*}" /proc/modules \
  && echo "  `dmesg |sed -n '/ath6kl: ar6003 .* fw/h;$g;$s/^.*ath6kl: //p'`" \
  || echo "  ..."

  echo -e \
  "\nProcesses related for ${WIFI_DRIVER}:\n  ...\r\c"
  top -bn1 \
  |sed -e '/sed/d;s/\(^....[^ ]\)\ \+[^ ]\+\ \+[^ ]\+\ \+\(.*\)/\1 \2/' \
       -e '4h;/.[dp].supp/H;/event_m/H;/sdcu/H' \
       -e "/${module%%_*}"'/H;${x;p}' -n

  if wifi_queryinterface
  then
    sed 's/^Inter-/\n\/proc\/net\/wireless:\n&/;$a' \
      /proc/net/wireless 2>/dev/null || echo

    iw dev $WIFI_DEV link \
      |sed 's/onnec/ssocia/;s/cs/as/;s/Cs/As/;s/(.*)//;/[RT]X:/d;/^$/,$d'
  else
    echo
  fi
  echo
}

wifi_queryinterface() {
  # on driver init, must check and wait for device
  # arg1 is timeout (deciseconds) to await availability
  let x=0 timeout=${1:-0} && msg -n '  '
  while [ $x -le $timeout ]
  do
    if [ -z "$WIFI_DEV" ]
    then # determine iface via device path
      for wl_dev in /sys/class/net/*/phy80211
      do
        test -d "${wl_dev//\*}"/device/subsystem/drivers/$WIFI_DRIVER \
          && WIFI_DEV=${wl_dev#*net/} WIFI_DEV=${WIFI_DEV%/*} \
          && break
      done
    fi
    if [ -n "$WIFI_DEV" ] \
    && read -rs wl_mac < /sys/class/net/$WIFI_DEV/address
    then # check if device address is available/ready
      [ "${wl_mac/??:??:??:??:??:??/addr}" == addr ] && break
    else
      let $timeout || break
    fi
    usleep 87654 && { let x+=1; msg -n .; }
  done 2>/dev/null
  let $x && msg ${x}00mSec
  test -n "$WIFI_DEV"
}

wifi_reset_gpio(){
  msg "  ...mmc failed to register, retrying: ${WIFI_DEV:-?}";
  reset_gpio_path=/sys/module/ath6kl_sdio/parameters/reset_pwd_gpio
  if [ -f "$reset_gpio_path" ]
  then
    { read -r reset_pwd_gpio < "$reset_gpio_path"; } 2>/dev/null
    case $reset_pwd_gpio in
    #WB50
      "131")
      echo 0 > /sys/class/gpio/pioE3/value
      usleep 2500
      echo 1 > /sys/class/gpio/pioE3/value
      usleep 2500
      break
      ;;
    #WB45
    "28")
      echo 0 > /sys/class/gpio/pioA28/value
      usleep 2500
      echo 1 > /sys/class/gpio/pioA28/value
      usleep 2500
      break
      ;;
    *)
      msg "  ...reset GPIO not found: ${WIFI_DEV:-?}";
      ;;
    esac
  fi
}

wifi_start() {
  wifi_lock_wait
  if grep -q "$WIFI_DRIVER" /proc/modules
  then
    msg "checking interface/mode"
    ## see if this 'start' has a fips-mode conflict
    if ! wifi_queryinterface
    then
      msg ${PS1}${0##*/} $flags restart
      exec $0 $flags restart
    else
      msg "  ...n/a"
    fi
  else
    ## check for 'slot_b=' setting in kernel args
    grep -o 'slot_b=.' /proc/cmdline \
    && msg "warning: \"slot_b\" setting in bootargs"

    modprobe $WIFI_DRIVER \
    || { msg "  ...driver failed to load"; return 1; }

    ## await enumerated interface
    wifi_queryinterface 27
    if [ ! -n "$WIFI_DEV"  ]
    then
      wifi_reset_gpio
      wifi_queryinterface 27 \
        || { msg "  ...driver init failure, iface n/a: ${WIFI_DEV:-?}"; }
    fi
  fi

  # enable interface
  [ -n "$WIFI_DEV" ] \
  && { msg -n "activate: $WIFI_DEV  ..."; wifi_set_dev up && msg ok; } \
  || { msg "iface $WIFI_DEV n/a, FW issue?  -try: wireless restart"; return 1; }

  # dynamic wait for socket args: <socket> <interval>
  await() { n=27; until [ -e $1 ] || ! let n--; do msg -n .; usleep $2; done; }

  # disable wifi for systems that are configured for dcas' ssh_disable
  CONF_FILE=/etc/dcas.conf
  [ -s $CONF_FILE ] && [ `grep ^ssh_disable $CONF_FILE` ] && $SDC_CLI disable

  # choose to run either hostapd or the supplicant (default)
  # check the /e/n/i wifi_dev stanza(s)
  stanza="/^iface ${WIFI_DEV} inet/,/^$/"

  # hostapd - enabled in /e/n/i -or- via cmdline
  if [ ! -f "$supp_sd/pid" -a "${1/*supp*/X}" != "X" -a "$1" != "manual" ] \
  && hostapd=$( sed -n "${stanza}{/hostapd/{s/[ \t]*//;/^[^#]/{p;q}}}" $eni ) \
  && [ -n "$hostapd" ]
  then
    if ! pidof sdcsupp >/dev/null
    then
      # launch supplicant if exists and not already running
      if test -e "$SDC_SUPP" && ! ps |grep -q "[ ]$SDC_SUPP" && let n=17
      then
        [ -f $supp_sd/pid ] \
        && { msg "$supp_sd/pid exists"; return 1; }

        supp_opt=$WIFI_80211\ $flags
        msg -n executing: $SDC_SUPP -i$WIFI_DEV $supp_opt -s'  '
        #
        $SDC_SUPP -i$WIFI_DEV $supp_opt -s >/dev/null 2>&1 &
        #
        await $supp_sd/$WIFI_DEV 500000
        # check and store the process id
        pidof sdcsupp 2>/dev/null >$supp_sd/pid \
        || { msg ..error; return 2; }
        msg .ok
      fi
      apmode=started
    fi
  fi

  # supplicant - enabled in /e/n/i -or- via cmdline
  if [ ! -f "$supp_sd/pid" -a "${1/*host*/X}" != "X" -a "$1" != "manual" ] \
  && sdcsupp=$( sed -n "${stanza}{/[dp].supp/s/[ \t]*//;/^[^#]/{p;q}}}" $eni ) \
  && [ -n "$sdcsupp" -o "${apmode:-not}" != "started" ]
  then
    # launch supplicant if exists and not already running
    if test -e "$SDC_SUPP" && ! ps |grep -q "[ ]$SDC_SUPP" && let n=17
    then
      [ -f $supp_sd/pid ] \
      && { msg "$supp_sd/pid exists"; return 1; }

      supp_opt=$WIFI_80211\ $flags
      msg -n executing: $SDC_SUPP -i$WIFI_DEV $supp_opt -s'  '
      #
      $SDC_SUPP -i$WIFI_DEV $supp_opt -s >/dev/null 2>&1 &
      #
      await $supp_sd/$WIFI_DEV 500000
      # check and store the process id
      pidof sdcsupp 2>/dev/null >$supp_sd/pid \
      || { msg ..error; return 2; }
      msg .ok
    fi
  fi

  if [ -e "$EVENT_MON" ] \
  && ! pidof event_mon >/dev/null
  then
    $EVENT_MON -ologging -b0x000000FFA3008000 -m &
    msg "  started: event_mon[$!]"
  fi
  return 0
}

wifi_stop() {
  wifi_lock_wait
  if [ -f /sys/class/net/$WIFI_DEV/address ]
  then
    { read -r ifs < /sys/class/net/$WIFI_DEV/operstate; } 2>/dev/null

    ## de-configure the interface
    # This step allows for a cleaner shutdown by flushing settings,
    # so packets don't use it.  Otherwise stale settings can remain.
    ip addr flush dev $WIFI_DEV && msg "  ...de-configured"

    ## terminate the supplicant by looking up its process id
    if { read -r pid < $supp_sd/pid; } 2>/dev/null && let pid+0
    then
      rm -f $supp_sd/pid
      wifi_kill_pid_of_service $pid sdcsupp
      let rv+=$?
    fi

    ## terminate event_mon
    killall event_mon 2>/dev/null \
         && msg "event_mon stopped"

    ## return if only stopping sdcsupp
    test "${1/*supp*/X}" == "X" \
      && { wifi_set_dev ${ifs/dormant/up}; return $rv; }

    ## disable the interface
    # This step avoids occasional problems when the driver is unloaded
    # while the iface is still being used.  The supp may do this also.
    wifi_set_dev down && msg "  ...iface disabled"
  fi

  ## unload ath6kl modules
  if mls=$( grep -os -e "^${WIFI_DRIVER%[_-]*}[^ ]*" /proc/modules )
  then
    msg unloading: $mls
    rmmod $mls
  fi

  [ $? -eq 0 ] && { msg "  ...ok"; return 0; } || return 1
}

wifi_kill_pid_of_service() {
  if kill $1 && n=27
  then
    msg -n $2 terminating.
    while [ -d /proc/$1 ] && let n--; do usleep 50000; msg -n .; done; msg
  fi
} 2>/dev/null

wifi_lock_wait() {
  w4it=27
  # allow upto (n) deciseconds for a prior stop/start to finish
  while [ -d /tmp/wifi^ ] && let --w4it; do usleep 98765; done
  mkdir -p /tmp/wifi^
} 2>/dev/null

# parse cmdline flags
while [ ${#1} -gt 1 ]
do
  case $1 in
    -h*) ## show usage
      break
      ;;
    -*) ## supplicant flags
      flags=${flags:+$flags }$1
      ;;
    *)
      break
  esac
  shift
done

eni=/etc/network/interfaces

# socket directories
supp_sd=/var/run/wpa_supplicant

# command
case $1 in

  stop|down)
    wifi_queryinterface
    echo Stopping wireless $WIFI_DEV $2
    wifi_stop $2
    ;;

  start|up)
    echo Starting wireless
    wifi_start $2 && wifi_config
    ;;

  restart)
    $0 stop $2 && exec $0 $flags start $2
    ;;

  status|'')
    wifi_status
    ;;

  -h|--help)
    echo "$0"
    echo "  ...stop/start/restart the '$WIFI_PREFIX#' interface"
    echo "Manages the wireless device driver '$WIFI_DRIVER'"
    echo
    echo "AP association is governed by the 'sdc_cli' and an active profile."
    echo
    [ "settings" == "$2" ] && grep "^WIFI_[A-Z]*=" $0 && echo
    echo "Flags:  (passed to supplicant)"
    echo "  -t  timestamp debug messages"
    echo "  -d  debug verbosity is multilevel"
    echo "  -b  specify bridge interface name (-bbr0)"
    echo
    echo "Option:  (link service to invoke)"
    echo "  supp  ..target the supplicant"
    echo "  host  ..target AP mode"
    echo "  manual  ..no service"
    echo
    echo "Usage:"
    echo "# ${0##*/} {stop|start|restart|status} [option]"
    ;;

  *)
    false
    ;;
esac
E=$?
rm -fr /tmp/wifi^
exit $E
