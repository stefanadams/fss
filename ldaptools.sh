if [ -f "/etc/openldap/ldap.conf" ]; then
	export BASEDN=$(grep BASE /etc/openldap/ldap.conf | sed -r 's/^BASE\s+//')
	export LDAPBASEDN=$BASEDN
	if [ $USER == 'root' ]; then
		export LDAPUSER="cn=Manager" 
		export PASSFILE="/etc/ldap.secret"
		export LDAPPASSFILE="/etc/ldap.secret"
	else
		export LDAPUSER="uid=$USER,ou=People";
		if [ -f "$HOME/.ldap/secret" ]; then
			chmod -R 700 ~/.ldap
		else
			if [ "$LDAPPASSWORD" ]; then
				mkdir -p $HOME/.ldap
				echo $LDAPPASSWORD > $HOME/.ldap/secret
				chmod -R 700 ~/.ldap
			else
				if [ "$BASH_SOURCE" == "/etc/profile.d/ldaptools.sh" ]; then
					echo To autofill your LDAP password: export LDAPPASSWORD=\"YourPassword\" \&\& . $BASH_SOURCE
				fi
			fi
		fi
		export PASSFILE="$HOME/.ldap/secret"
		export LDAPPASSFILE="$HOME/.ldap/secret"
	fi
fi
function ldapsearch {
	if [ -r $LDAPPASSFILE ]; then
		/usr/bin/ldapsearch -x -w $(cat $LDAPPASSFILE) -D "$LDAPUSER,$BASEDN" "$@"
	else
		/usr/bin/ldapsearch -x -W -D "$LDAPUSER,$BASEDN" "$@"
	fi
}
function ldapmodify {
	if [ -r $LDAPPASSFILE ]; then
		/usr/bin/ldapmodify -x -w $(cat $LDAPPASSFILE) -D "$LDAPUSER,$BASEDN" "$@"
	else
		/usr/bin/ldapmodify -x -W -D "$LDAPUSER,$BASEDN" "$@"
	fi
}
function ldapdelete {
	if [ -r $LDAPPASSFILE ]; then
		/usr/bin/ldapdelete -x -w $(cat $LDAPPASSFILE) -D "$LDAPUSER,$BASEDN" "$@"
	else
		/usr/bin/ldapdelete -x -W -D "$LDAPUSER,$BASEDN" "$@"
	fi
}
function ldappasswd {
	if [ -r $LDAPPASSFILE ]; then
		/usr/bin/ldappasswd -x -w $(cat $LDAPPASSFILE) -D "$LDAPUSER,$BASEDN" "$@"
	else
		/usr/bin/ldappasswd -x -W -D "$LDAPUSER,$BASEDN" "$@"
	fi
}
function ldapadd {
	if [ -r $LDAPPASSFILE ]; then
		/usr/bin/ldapadd -x -w $(cat $LDAPPASSFILE) -D "$LDAPUSER,$BASEDN" "$@"
	else
		/usr/bin/ldapadd -x -W -D "$LDAPUSER,$BASEDN" "$@"
	fi
}
