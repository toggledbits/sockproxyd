`sockproxyd` implements a pass-through socket proxy for Vera Luup and openLuup systems that bidirectionally passes data between two connections &mdash; one the Luup system and one a remote endpoint. It was created because Luup's structure does not lend itself to blocking on I/O, and existing Lua socket libraries are not readily made to yield when they would block. The typical alternative, then, is polling the socket with a low or zero timeout to see if data is waiting, but this always causes lags in response, and always results in excess labor when no data is waiting--a high percentage of the time.

To solve this, the proxy notifies, via action invocation, a Luup device that data is waiting on the socket. The plugin/device need not poll, but rather just read the socket when its notification action is invoked by `sockproxyd`.

The proxy is meant to run as a background task on the system, started before LuaUPnP (Vera) or openLuup; using an `/etc/init.d` script is the recommended method. The proxy can manage multiple connections efficiently, so one running instance of the proxy should be sufficient to serve any reasonable number of plugins. It is not necessary (and not advised) to go proxy-per-plugin.

## Using the Proxy

When first connecting to the proxy, it is in "setup mode". In this mode, a small set of
commands can be sent (all commands must be terminated with newline):

    RTIM ms                 Receive timeout in milliseconds. If data is not received from the
                            remote for longer than this period, the remote is disconnected. The
                            default is 0, meaning no timeout is enforced.
    BLKS nbytes             Set the network block size to nbytes. The default is DEFAULT_BLOCKSIZE. Messages
                            larger than the network block size are received nbytes chunks. It is
                            usually not necessary to change this.
    NTFY dev sid act pid    Set the device, serviceID, and action to be used for notification
                            of waiting receive data. If not used, no notification is invoked.
                            The optional "pid" can be used as an identifier for each connection
                            if a client device has multiple connections through the proxy (i.e.
                            it tells you which connection has available data).
    PACE seconds            Limits the pace with which received-data notifications are sent
                            to not more than once every "seconds" seconds. Default: 0, waiting
                            received sends an immediate notification. If a number of datagrams
                            are received in a short time, this can result in the proxy "spamming"
                            the plugin/device. Setting the frequency higher prevents this, but
                            then requires the plugin/device to scan for further data for an equal
                            period of time. That is, if the pace is 2 seconds, the plugin should
                            loop attempting to read data for 2 seconds (at least) when notified,
                            in case more data comes in during the notification pause.
    CONN host:port options  Connects (TCP) to host:port, and enters "echo mode". This should
                            always be the last setup command issued; it is not possible to issue
                            other setup commands after connecting to the remote host. The options
                            can by any of RTIM, PACE, BLKS, or NTFY written as key value pairs,
                            for example: 
                            
                            CONN 192.168.0.2:25 BLKS=514 PACE=1 NTFY=659/urn:toggledbits-com:serviceId:Example1/HandleReceive/0
                            
                            This accomplishes multiple commands on a single line and makes it easier
                            to adapt the proxy to existing applications.

When a host first connects to the proxy, the initial greeting is sent. This greeting is always
"OK TOGGLEDBITS-SOCKPROXY n pid", where N is the integer version number of the proxy. If your
plugin can work with different versions of the proxy, you can parse out the version number. The
host can then issue any necessary setup commands, and end with the CONN command to connect the
remote host and enter echo mode. The "pid" is the connection identfier, which by default will be 
passed as the "Pid" parameter on action requests/notifications (unless changed by NTFY).

Once in echo mode, the proxy passes data between the client connection (between the Vera device
and the proxy) and the remote connection (between the proxy and the other endpoint). This con-
tinues until either end closes the connection or an error occurs. Closure of connections is al-
ways symmetrical: if the remote closes, the client closes; if the client closes, the remote
closes. This assures that a client is not communicating to nothing, and that the proxy behaves
as much like a direct connection as possible. This means that the proxy should be transparent
to WSAPI, etc.

The proxy's setup mode includes a couple of commands to help humans that connect to it:
    STAT            Shows the status of all connections the proxy is managing.
    CAPA            Shows the capabilities of this version of the proxy (also machine-readable)
    QUIT            Disconnect the current connection from the proxy.
    STOP            Close all connections and stop the proxy daemon.
    HELP            Print command help.

## Starting sockproxyd

The daemon is meant to be started at system startup (e.g. from /etc/init.d on legacy Veras).

The following command line options are supported:

    -a _address_    The address on which to bind (default: *, all addresses/interfaces)
    -p _port_       The port to listen on for proxy connections (default: DEFAULT_PORT)
    -L _logfile_    The log file to use
    -N _url_        The base URL for reaching the Luup system (default: http://127.0.0.1:3480)
    -D              Enable debug logging

## Adapting Plugins/Applications

Here's a typical method for connecting to a remote host:

```
function connect( ip, port )
	local socket = require "socket"
	local sock = socket.tcp()
	sock:settimeout( 5 )
	-- Connect directly to target
	if sock:connect( ip, port ) then
		return true, sock
	end
	sock:close()
	return nil -- failed to connect
end
```

Here's the same function, modified to try the proxy connection first. The proxy is assumed to be running on `localhost` with the default port (2504):

```
function connect( ip, port )
	local socket = require "socket"
	local sock = socket.tcp()
	sock:settimeout( 5 )
	-- Try proxy connection
	if sock:connect( "127.0.0.1", 2504 ) then
		-- Accepted connection, connect proxy to target and go into echo mode
		sock:settimeout( 2 )
		sock:send( string.format( "CONN %s:%s\n", ip, port ) )
		local ans = sock:receive( "*l" )
		if ans:match( "^OK CONN" ) then
			-- Socket connected to proxy, and proxy is connected to remote in echo mode
			return true, sock
		end
		-- Unhappy handshake; close and get new socket for direct connection
		sock:shutdown("both")
		sock:close()
		sock = socket.tcp()
	end
	-- Connect directly to target
	if sock:connect( ip, port ) then
		return true, sock
	end
	sock:close()
	return nil -- failed to connect
end
```

## LICENSE

sockproxyd is offered under GPLv3.
