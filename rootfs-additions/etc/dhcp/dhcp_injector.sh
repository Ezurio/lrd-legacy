#!/usr/bin/env ash

# Copyright (c) 2015, Laird Connectivity
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

# Event
case ${reason} in
	PREINIT)
		dhcp_injector -s DECONFIG
		;;

	RENEW)
		dhcp_injector -s RENEWED
		;;

	BOUND|REBOOT)
		dhcp_injector -s BOUND
		;;

	FAIL)
		dhcp_injector -s LEASEFAIL
		;;

	NAK)
		dhcp_injector -s NAK
		;;

	STOP|EXPIRE)
		dhcp_injector -s RELEASED
		;;
esac

exit 0;
