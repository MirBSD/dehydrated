#!/bin/mksh
#-
# install -c -o 0 -g bin -m 555 docs/examples/mbsdcert.sh /usr/local/libexec/
# - and add to sudoers:
#  _acme	ALL = NOPASSWD: /usr/local/libexec/mbsdcert.sh

set -e
set -o pipefail
umask 077
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
		if ! key=$(print -nr -- "$buf" | openssl rsa) 2>&1; then
			print -ru2 E: could not read private key
			exit 1
		fi
		key+=$nl
		s=1
		;;
	(*)
		if ! line=$(print -nr -- "$buf" | openssl x509) 2>&1; then
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
	print -nr -- "$content" >"$fn"
}

if [[ -s /etc/ssl/dhparams.pem ]]; then
	dhp=$(</etc/ssl/dhparams.pem)$nl
else
	dhp=
fi

dofile 0644 0:0 /etc/ssl/default.cer "$cer$dhp"
dofile 0644 0:0 /etc/ssl/deflt-ca.cer "$chn"
[[ -n $dhp ]] && dofile 0644 0:0 /etc/ssl/dhparams.pem "$dhp"
dofile 0644 0:0 /etc/ssl/imapd.pem "$cer$chn"
dofile 0640 0:ssl-cert /etc/ssl/private/default.key "$key"
dofile 0640 0:ssl-cert /etc/ssl/private/stunnel.pem "$key$cer$chn"

if (( rv )); then
	rm -f "${rename_src[@]}"
	exit $rv
fi

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

print -ru2 "W: reboot this system within the next four weeks!"
exit 0
