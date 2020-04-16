# (C) 2020 Patrick H. Rigney, All Rights Reserved; part of SockProxy
# init script for Vera systems
# https://github.com/toggledbits/sockproxyd

START=80

USE_PROCD=1
PROG=/usr/local/bin/sockproxyd.lua
LOGFILE=/tmp/sockproxyd.log

start_service () {
    procd_open_instance
    procd_set_param command lua "$PROG" -L "$LOGFILE"
    procd_set_param pidfile /var/run/sockproxyd.pid
    procd_set_param limits core="unlimited"
    procd_set_param respawn 3600 90 10
    procd_close_instance
}