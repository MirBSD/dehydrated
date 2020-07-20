#!/bin/mksh
# -*- mode: sh -*-
#-
# Copyright © 2018, 2019, 2020
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
# Example hook for deployment on Debian, with debian-cert.sh from this
# directory serving as a filter for the incoming data.
# - crontab:
#  15 8 * * 0 /bin/mksh /home/acme/repo/dehydrated/dehydrated -c | /usr/bin/logger -t dehydrated
# - config (/home/acme/config@ -> /home/acme/certbot/config)
#  BASEDIR=/home/acme/certbot
#  CHALLENGETYPE=dns-01
#  HOOK=/home/acme/repo/dehydrated/docs/examples/debian-hook-dns.sh
# and set CONTACT_EMAIL and create /home/acme/certbot/domains.txt
#
# Needs bind9-dnsutils installed and $BASEDIR/dns.key populated.
# Setup: split zones for LAN vs challenge domains:
#	_acme-challenge.HOST.dom.tld is a CNAME pointing to
#	_acme-challenge.HOST.U.dom.tld (where HOST may have
#	subdomain parts); the primary NS for U.dom.tld will
#	be sent nsupdate requests.
# bind9-dnsutils is called just dnsutils before bullseye.

print -nr -- "D: debian-hook-dns.sh invoked with: "
for i in "$@"; do
	print -nr -- "${i@Q} "
done
print -r -- "#"

function die {
	print -r -- "E: $*"
	exit 1
}

extdns=8.8.8.8
function nslook {
	REPLY=$(dig @"$extdns" -q "$2" -r -t "$1" +short) || \
	    die "couldn’t nslookup $*"
}
function do_dns {
	set -o noglob
	local hn=$1 pre=$2 suf=$3
	local cn zone svr i j x y

	# determine FQDN of localhost
	if [[ -z $hn ]]; then
		hn=$(hostname)
		[[ $hn = *.* ]] || hn=$(hostname -f)
	fi
	hn=${hn%%+(.)}
	[[ $hn = [A-Za-z0-9]?(*([A-Za-z0-9-])[A-Za-z0-9])+(.[A-Za-z0-9]?(*([A-Za-z0-9-])[A-Za-z0-9])) ]] || \
	    die "cannot get FQDN: ${hn@Q}"
	IFS=.
	set -- $hn
	IFS=$' \t\n'
	# retrieve CNAME for update zone
	cn=${|nslook CNAME _acme-challenge."$hn";}
	[[ $cn = [A-Za-z0-9]?(*([A-Za-z0-9-])[A-Za-z0-9])+(.[A-Za-z0-9]?(*([A-Za-z0-9-])[A-Za-z0-9])). ]] || \
	    die "cannot get CNAME: ${cn@Q}"
	# determine split
	zone=
	i=0
	while (( ++i < $# )); do
		x=
		y=
		j=0
		while (( ++j <= $# )); do
			if (( j <= i )); then
				eval "x+=\$$j."
			else
				eval "y+=\$$j."
			fi
		done
		[[ $cn = ?(*.)"$x"*."$y" ]] || continue
		zone=${cn#?(*.)"$x"}
		zone=${zone%.}
		break
	done
	[[ -n $zone ]] || die "cannot determine split for $cn"
	# find update server
	set -- ${|nslook SOA "$zone";}
	svr=${1%%+(.)}
	shift
	[[ $svr = [A-Za-z0-9]?(*([A-Za-z0-9-])[A-Za-z0-9])+(.[A-Za-z0-9]?(*([A-Za-z0-9-])[A-Za-z0-9])) ]] || \
	    die "cannot get update server: ${svr@Q} $*"
	# run the update
	if ! nsupdate -k "$BASEDIR/dns.key"; then
		die "cannot update DNS"
	fi <<-EOF
		server $svr
		zone $zone
		$pre $cn $suf
		send
	EOF
	print -ru2 -- "I: DNS01 update done"
}

case $1 {
(deploy_cert)
	# handled below
	;;
(startup_hook)
	mtime=$(stat -c %Y /etc/ssl/default.cer)
	[[ $mtime = +([0-9]) ]] || mtime=0
	if (( (${EPOCHREALTIME%.*} - mtime) > (66 * 86400) )); then
		print -ru2 'E: /etc/ssl/default.cer is older than 66 days, smells fishy'
	fi
	exit 0
	;;
(deploy_challenge)
	[[ $4 = *\"* ]] && die "challenge contains double quotes! ${4@Q}"
	do_dns "$2" "update add" "300 IN TXT \"$4\""
	exit 0
	;;
(clean_challenge)
	[[ $4 = *\"* ]] && die "challenge contains double quotes! ${4@Q}"
	do_dns "$2" "update delete" "300 IN TXT \"$4\""
	exit 0
	;;
(*)
	# nothing more to do
	exit 0
	;;
}

# 1=deploy_cert 2=domain 3=privkey 4=cert 5=cert+chain 6=chain 7=timestamp
print '# from debian-hook-dns.sh' | \
    cat - "$3" "$4" "$6" | \
    sudo /usr/local/libexec/debian-cert.sh
# see there for the rest
