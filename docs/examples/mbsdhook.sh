#!/bin/mksh

print -nr -- "D: mbsdhook.sh invoked with: "
for i in "$@"; do
	print -nr -- "${i@Q} "
done
print -r -- "#"

case $1 {
(deploy_cert)
	# handled below
	;;
(startup_hook)
	if (( (${EPOCHREALTIME%.*} - $(stat -f %m /etc/ssl/default.cer)) > \
	    (66 * 86400) )); then
		print -ru2 'E: /etc/ssl/default.cer is older than 66 days, smells fishy'
	fi
	exit 0
	;;
(*)
	# nothing more to do
	exit 0
	;;
}

# 1=deploy_cert 2=domain 3=privkey 4=cert 5=cert+chain 6=chain 7=timestamp
print '# from mbsdhook.sh' | \
    cat - "$3" "$4" "$6" | \
    sudo /usr/local/libexec/mbsdcert.sh
# see there for the rest
