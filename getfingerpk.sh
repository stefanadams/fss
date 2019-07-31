#!/bin/sh
/usr/bin/smbclient -U fss -c "lcd /data/school/FSS;prompt;get Finger.pk" //hostname/fssbiowedge "$(cat /data/school/FSS/fssbiowedge.secret)"
