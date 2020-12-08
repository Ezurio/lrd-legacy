#!/usr/bin/env ash

# Copyright (c) 2020, Laird Connectivity
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

# /etc/dhcp/dhcpcd.sh
# An extended support wrapper for dhcpcd with process-id control.
#
# Usage:
# ./dhcpcd.sh -i<iface> [-qv] [-4] [-6] [stop|start|renew|release|check|status]
#
# The DHCP event handler is: /etc/dhcp/dhcpcd.script
# All options may be set in: /etc/dhcp/dhcpcd.conf
# Apply specific options in: /etc/dhcp/dhcpcd.<iface>.conf
# Option bootfile is set by: /tmp/bootfile_
# A few settings passed via environment.
#

msg() {
  echo "$@"
  echo "$@" >>${log:-/dev/null} || :
} && vm=.

eval ${DHCP_PARAMS}

# invocation
while let $#
do
  case $1 in
    -h) ## show usage
      exec sed -n "/^# .*${0##*/}/,/^[^#]/{s/^#/ /p}" $0
      ;;
    -q) ## quiet, no stdout
      vm=
      ;;
    -v) ## add verbosity, multi-level
      vm=${vm}.
      ;;
    -4) ## ipv4
      prt='-4'
      ;;
    -6) ## ipv6
      prt='-6'
      ;;
    -i*) ## interface
      [ -n "${1:2}" ] && dev=${1:2} || { dev=${2}; shift; }
      ;;
    -*) ## ignored
      ;;
    *) ## last arg
      act=$1
      break
  esac
  shift
done

# set some message levels according to verbose-mode
[ 0${#vm} -ge 1 ] && alias msg1=msg || alias msg1=:
[ 0${#vm} -ge 2 ] && alias msg2=msg || alias msg2=:

dhcpcd_conf() {
  ## specified interface must exist
  test -f /sys/class/net/${dev}/uevent \
    || { msg "required: -i<iface>"; return 1; }

  ## dir exists for dhcp
  test -d /var/lib/dhcp \
    || ln -s /tmp /var/lib/dhcp

  ## apply global conf options
  if [ -f /etc/dhcp/dhcpcd.conf ]
  then
    { set ${vm/..*/-x} --; }
    . /etc/dhcp/dhcpcd.conf
    { set +x; } 2>/dev/null
  fi
  ## apply select iface conf options
  if [ -f /etc/dhcp/dhcpcd.${dev}.conf ]
  then
    { set ${vm/..*/-x} --; }
    . /etc/dhcp/dhcpcd.${dev}.conf
    { set +x; } 2>/dev/null
  fi
  ## flag-file bootfile req
  if [ -f /tmp/bootfile_ ]
  then
    OPT_REQ="${OPT_REQ} bootfile_name"
  fi
} >>${log:-/dev/null} 2>&1

dhcpcd_start() {
  # set no-verbose or use a verbose mode level
  # udhcpc debug is offset from verbose level by 2
  [ ${#vm} -eq 0 ] && nv='>/dev/null'
  [ ${#vm} -eq 1 ] && nv=''
  [ ${#vm} -ge 2 ] && v='-d' vb='-v'

  # request ip-address (env)
  rip=${rip:+-r ${rip}}

  # specific options to request in lieu of defaults
  ropt=; for t in ${OPT_REQ/dhcp_lease_time/}; do ropt="${ropt} -o ${t}"; done

  # vendor-class-id support (as last line of file or a string)
  vci=$( sed '$!d;s/.*=["]\(.*\)["]/\1/' ${OPT_VCI:-/} 2>/dev/null \
      || echo "${OPT_VCI}" )
  vci=${vci:+-i $vci}
  ropt=${ropt}${vci:+ -o vendor_encapsulated_options}

  # run-script: /usr/share/udhcpc/default.script
  rs="-f /etc/dhcp/dhcpcd-master.conf"

  read hn < /proc/sys/kernel/hostname
  hsopt=${hn:+-h ${hn}}

  mopt=${metric:+-m ${metric}}

  # A run-script handles client event state actions and writes to a leases file.
  # Client normally continues running in background, and upon obtaining a lease.
  # And it may be signalled or re-spawned again, depending on events/conditions.
  # Flags are:
  # iface, verbose, request-ip, exit-no-lease/quit-option, exit-release
  dhcpcd ${v} ${rip} ${prt} -b -L ${hsopt} ${mopt} ${ropt} ${vci} ${rbf} ${rs} -e DHCP_PARAMS="vb=${vb} log=${log} mpr=${mpr} weight=${weight}" ${dev} ${nv}

} >>${log:-/dev/null}

dhcpcd_signal() {
  [ "${1}" == TERM ] && rv=0 || rv=1

  [ -e /var/run/dhcpcd/${dev}${prt}.pid ] || return ${rv}

  read -r pid < /var/run/dhcpcd/${dev}${prt}.pid && \
  read client < /proc/${pid}/comm || \
  return ${rv}

  case ${1} in
    RELEASE)
      action=release
      dhcpcd -k ${prt} ${dev} ; rv=$?
      ;;

    RENEW)
      action=renew
      dhcpcd -N ${prt} ${dev} ; rv=$?
      ;;

    TERM)
      action=terminate
      dhcpcd -x ${prt} ${dev} ; rv=$?
      ;;

    CHECK)
      action=check
      kill -0 ${pid}; rv=$?
      ;;
   esac

   msg1 "  ${pid}_${client} <- ${action} ${rv}"
   return ${rv}
} >>${log:-/dev/null} 2>/dev/null

# main
case ${act:-status} in
  stop) ## terminate
    dhcpcd_signal TERM
    ;;

  start) ## (re)spawn
    if ! dhcpcd_signal CHECK ; then
      dhcpcd_conf || exit $?
      dhcpcd_start || exit $?
    fi
    ;;

  release) ## deconfigure
    # Release will stop dhcpcd so do nothing
    # dhcpcd will release ip address on it's own
    ;;

  renew) ## request
    dhcpcd_signal RENEW
    ;;

  check) ## is running
    dhcpcd_signal CHECK
    ;;

  status) ## event-state-action and process-id
    echo ": ${leases:=/var/lib/dhcp/dhclient.${dev}.leases}"
    grep -s '^# esa:' ${leases} || msg \ \ ...
    pgrep -af "dhcpcd[^.].*${dev}" || { msg \ \ ...; false; }
esac
