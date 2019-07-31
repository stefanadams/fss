#!/bin/bash

source /etc/profile.d/ldaptools.sh
xls=$(basename $1 .xls)
ldapsearch -LLL -b "ou=Devices,o=local" > devices.$$.ldif
perl device2ldap.pl $xls.xls > $xls.$$.ldif
for i in $(grep -e "^dn: " $xls.$$.ldif | cut -d ' ' -f 2); do echo $i; ldapdelete $i; done
ldapadd -f $xls.$$.ldif 
