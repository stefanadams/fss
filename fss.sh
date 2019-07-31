#!/bin/sh

# This is the loginShell for user fss

. /data/school/FSS/ldaptools.sh
clear
#echo "The auditing tool is under maintenance.  Please contact your systems administrator for further information."; exit
while [ $? -eq 0 ]; do
	/data/school/FSS/fss.pl -C
done
