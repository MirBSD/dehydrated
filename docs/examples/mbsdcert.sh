#!/bin/mksh
# -*- mode: sh -*-
#-
# Copyright © 2018, 2019
#	mirabilos <mirabilos@evolvis.org>
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# “Software”), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#-
# install -c -o 0 -g bin -m 555 docs/examples/mbsdcert.sh /usr/local/libexec/
# - and add to sudoers:
#  _acme	ALL = NOPASSWD: /usr/local/libexec/mbsdcert.sh

set -e
set -o pipefail
umask 077
cd /
set +e

if (( USER_ID )); then
	print -ru2 E: need root
	exit 1
fi

IFS= read -r line
if [[ $line != '# from mbsdhook.sh' ]]; then
	print -ru2 E: not called from dehydrated hook script
	exit 1
fi

nl=$'\n'
key=
cer=
chn=
buf=
s=0

while IFS= read -r line; do
	buf+=$line$nl
	[[ $line = '-----END'* ]] || continue
	case $s {
	(0)
		if ! key=$(print -nr -- "$buf" | \
		    sudo -u nobody openssl rsa) 2>&1; then
			print -ru2 E: could not read private key
			exit 1
		fi
		key+=$nl
		s=1
		;;
	(*)
		if ! line=$(print -nr -- "$buf" | \
		    sudo -u nobody openssl x509) 2>&1; then
			print -ru2 E: could not read certificate $s
			exit 1
		fi
		if (( s == 1 )); then
			cer=$line$nl
		else
			chn+=$line$nl
		fi
		s=2
		;;
	}
	buf=
done

case $s {
(0)
	print -ru2 -- E: private key missing
	exit 1
	;;
(1)
	print -ru2 -- E: certificate missing
	exit 1
	;;
(2)
	if [[ -z $chn ]]; then
		print -ru2 -- E: expected a chain of at least length 1
		exit 1
	fi
	;;
(*)
	print -ru2 -- E: cannot happen
	exit 255
	;;
}

set -A rename_src
set -A rename_dst
nrenames=0
rv=0

function dofile {
	local mode=$1 owner=$2 name=$3 content=$4 fn

	(( rv )) && return

	if ! fn=$(mktemp "$name.XXXXXXXXXX"); then
		print -ru2 "E: cannot create temporary file for $name"
		rv=2
		return
	fi
	rename_src[nrenames]=$fn
	rename_dst[nrenames++]=$name
	chown "$owner" "$fn"
	chmod "$mode" "$fn"
	if ! print -nr -- "$content" >"$fn"; then
		print -ru2 "E: cannot write to temporary file for $name"
		rm -f "$fn"
		rv=2
		return
	fi
}

if [[ -s /etc/ssl/dhparams.pem ]]; then
	dhp=$(</etc/ssl/dhparams.pem)$nl
else
	dhp=
fi

dofile 0644 0:0 /etc/ssl/default.cer "$cer$dhp"
dofile 0644 0:0 /etc/ssl/deflt-ca.cer "$chn"
[[ -n $dhp ]] && dofile 0644 0:0 /etc/ssl/dhparams.pem "$dhp"
dofile 0644 0:0 /etc/ssl/imapd.pem "$cer$chn$dhp"
dofile 0640 0:ssl-cert /etc/ssl/private/default.key "$key"
dofile 0640 0:ssl-cert /etc/ssl/private/stunnel.pem "$key$cer$chn$dhp"

if (( rv )); then
	rm -f "${rename_src[@]}"
	exit $rv
fi

sync
while (( nrenames-- )); do
	if ! mv "${rename_src[nrenames]}" "${rename_dst[nrenames]}"; then
		print -ru2 "E: rename ${rename_src[nrenames]@Q}" \
		    "${rename_dst[nrenames]@Q} failed ⇒ system hosed"
		exit 3
	fi
done

rm -f /etc/ssl/private/imapd.pem
if ! ln /etc/ssl/private/default.key /etc/ssl/private/imapd.pem; then
	print -ru2 "E: could not hardlink /etc/ssl/private/imapd.pem"
	exit 3
fi
sync

readonly p=/sbin:/bin:/usr/sbin:/usr/bin
rc=0
function svr {
	local rv iserr=$1; shift
	/usr/bin/env -i PATH=$p HOME=/ "$@" 2>&1
	rv=$?
	(( rv )) && if (( iserr )); then
		print -ru2 "E: errorlevel $rv trying to $*"
		rc=1
	else
		print -ru1 "W: errorlevel $rv trying to $*"
	fi
	#(( rv )) || print -ru1 "I: ok trying to $*"
}

function tkill {
	local x=$*

	[[ -n $x ]] && kill $x
}

# restart affected services
#pid= cmd=
#{ read pid; IFS= read -r cmd; } </var/run/sendmail.pid
#tkill $pid $(cat /var/www/logs/httpd.pid 2>/dev/null)
#sleep 1
#svr 1 /usr/sbin/httpd -u -DSSL
#[[ -n $cmd ]] && svr 1 $cmd
#exit $rc

# ideally one would only restart affected services here
print -ru2 "W: reboot this system within the next four weeks!"
exit 0
