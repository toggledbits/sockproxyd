#!/bin/sh /etc/rc.common

START=80

USE_PROCD=1
PROG=/etc/cmh-ludl/sockproxyd.lua
LOGFILE=/tmp/sockproxyd.log

start_service () {
        procd_open_instance
        procd_set_param command lua "$PROG" -L "$LOGFILE"
        procd_set_param pidfile /var/run/sockproxyd.pid
        procd_set_param limits core="unlimited"
        procd_close_instance
}
