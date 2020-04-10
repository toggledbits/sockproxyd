`sockproxyd` implements a pass-through socket proxy for Vera Luup and openLuup systems that bidirectionally passes data between two connections &mdash; one the Luup system and one a remote endpoint. It was created because Luup's structure does not lend itself to blocking on I/O, and existing Lua socket libraries are not readily made to yield when they would block. The typical alternative, then, is polling the socket with a low or zero timeout to see if data is waiting, but this always causes lags in response, and always results in excess labor when no data is waiting--a high percentage of the time.

To solve this, the proxy notifies, via action invocation, a Luup device that data is waiting on the socket. The plugin/device need not poll, but rather just read the socket when its notification action is invoked by `sockproxyd`.

The proxy is meant to run as a background task on the system, started before LuaUPnP (Vera) or openLuup; using an `/etc/init.d` script is the recommended method. The proxy can manage multiple connections efficiently, so one running instance of the proxy should be sufficient to serve any reasonable number of plugins. It is not necessary (and not advised) to go proxy-per-plugin.

Unless changed with startup options, the proxy listens on all interfaces on port 2504 by default, and assumes that Luup requests can be issued to `http://127.0.0.1:3480`.

## Installation

### Installing on Vera

To install on a Vera system:

1. Download the [latest release package](https://github.com/toggledbits/sockproxyd/releases) from Github;
2. Unzip the file contents;
2. Open *Apps > Develop apps > Luup files* in your browser;
3. Select all of the files in the "plugin" subfolder (not the folder itself) and drag them as a group to the Upload area.

Your system will reboot in about 60-90 seconds after install. This is necessary because the proxy is installed as a system background process that starts at boot.

### Installing on openLuup

Since each openLuup installation is different, there are no specific installation instructions. However, the following is what you need to accomplish using your ample Linux administration skills:

1. Launch the `sockproxyd.lua` file as system startup, before starting openLuup;
2. Launch it with the '-L' option to put the log file someplace sane.

It's not hard.

The following command line options are supported by the daemon:

    -a _address_    The address on which to bind (default: *, all addresses/interfaces)
    -p _port_       The port to listen on for proxy connections (default: 2504)
    -L _logfile_    The log file to use (default: stderr)
    -N _url_        The base URL for reaching the Luup system (default: http://127.0.0.1:3480)
    -D              Enable debug logging (default: debug off)

A template `init.d` script called `init-script.sh` is included in the distribution. It can be copied to `/etc/init.d/sockproxyd`, and should then be symlinked to `/etc/rc.d/S80sockproxyd` or similar. There are various ways for doing this, all slightly different per OS, so if you're an openLuup user setting this up, your Linux administration skills are being called upon.

## Developer Info

In this section, we'll talk about how the proxy works, and how you make use of it in existing or new plugins.

### How It Works

When first connecting to the proxy, it is in "setup mode". In this mode, a small set of commands can be sent (all commands must be terminated with newline):

    CONN host:port [options]    Opens a (TCP) connection to the remote endpoint at host:port, and 
                                enters "echo mode". Once in echo mode, further commands cannot be
                                sent &mdash; the proxy is not a bidirectional conduit to the remote.
    STAT                        Shows the status of all connections the proxy is managing.
    CAPA                        Shows the capabilities of this version of the proxy (also machine-readable)
    QUIT                        Disconnect the current connection from the proxy.
    STOP                        Close all connections and stop the proxy daemon.
    HELP                        Print command help.

The CONN command is really the main command for the proxy, and is likely the only command you will issue from your device/plugin. Options for the CONN command are structured as space-separated `key=value` pairs and may be given in any order (after the host:port, which must always come first). The following options are currently defined:

    RTIM=ms                 Receive timeout in milliseconds. If data is not received from the
                            remote for longer than this period, the remote is disconnected. The
                            default is 0, meaning no timeout is enforced.
    BLKS=nbytes             Set the network block size to nbytes. The default is 2048. Messages
                            larger than the network block size are received nbytes chunks. It is
                            usually not necessary to change this.
    NTFY=dev/sid/act[/pid]  Set the device, serviceID, and action to be used for notification
                            of waiting receive data. If not used, no notification action is invoked.
                            The optional "pid" (string) can be used as an identifier for each conn-
                            ection if a client device has multiple connections through the proxy
                            (i.e. it tells you which connection has available data). See the
                            "Multiple Connections" section below for more information about that.
    PACE=seconds            Limits the pace with which received-data notifications are sent
                            to not more than once every "seconds" seconds. Default: 0, waiting
                            data sends an immediate notification. If a number of datagrams are
                            received in a short time, this can result in the proxy "spamming" the
                            plugin/device. Setting the frequency higher prevents this, but then
                            requires the plugin/device to scan for further data for an equal period
                            of time. That is, if the pace is 2 seconds, the plugin should loop
                            attempting to read data for 2 seconds (at least) when notified, in case
                            more data comes in during the notification pause.

When a host first connects to the proxy, the initial greeting is sent. This greeting is always
`OK TOGGLEDBITS-SOCKPROXY n pid`, where _n_ is the integer version number of the proxy. If your
plugin can work with different versions of the proxy, you can parse out the version number. The
_pid_ is the connection identifier for the proxy session. If your plugin/device will be making several
connections through the proxy, you can parse the _pid_ from the greeting, or supply a different _pid_
to the CONN command's NTFY option, so that you can distinguish notifications for one endpoint from
the others.

All commands sent to the proxy must end in a single *newline* (ASCII 10) character (carriage return, ASCII 13, is not accepted or allowed alone or in combination with newline). The greeting and all replies to commands sent by the proxy will also terminate in a single newline. This makes them safe and easy to read with `sock:receive("*l")`. Command replies follow the form "OK <command>" or "ERR <command> <message>". For some commands, the OK response will include additional data.

Let's say, for example, that we've defined a `HandleReceive` action in the `urn:example-com:serviceId:Example1` service defined by our plugin, and our plugin is device #123. To connect to a remote endpoint at 192.168.0.155 port 3232, and have that action invoked every time receive data is available on the socket from the remote, we would issue the following CONN command:

    CONN 192.168.0.155:3232 NTFY=123/urn:example-com:serviceId:Example1/HandleReceive

The proxy will reply with `OK CONN pid`, and from that point, the proxy is in echo (pass-thru) mode bidirectionally--all data sent by the plugin to the proxy socket is sent to the remote unmodified; all data received from the remote causes the `HandleReceive` action to be invoked, so that the plugin/device can read the data from the proxy socket. This continues until either the plugin or the remote terminates the connection, at which point there is a final notification after the connection is closed (a `receive()` call on the socket will return `nil,"closed"` as usual for LuaSocket).

The commands other than CONN are really intended for humans. The STAT command, in particular, is helpful for figuring out what is connected to the proxy and what it is talking to. The STOP command will shut the proxy down (e.g. on the command line `echo STOP | nc localhost 2504` or similar will stop the proxy).

Here's a typical "human" session with the proxy:

```
$ nc -v 127.0.0.1 2504
Connection to 127.0.0.1 2504 port [tcp/*] succeeded!
OK TOGGLEDBITS-SOCKPROXY 1 1716058a203
STAT
 ID               St Client           Remote              #recv   #xmit Notify
 1716057f6c0      2  192.168.0.20     192.168.0.15:25      1449      27 601.urn:toggledbits-com:serviceId:MailSensor1/NotifyData/171604d50b7
*1716058a203      1  127.0.0.1                                0       0
 17160581a1f      2  192.168.0.20     192.168.0.7:10006     584     174 659/urn:toggledbits-com:serviceId:HTDLC1/HandleReceive/0
QUIT
OK QUIT
```

The above shows three connections. The first line shows a connection from a Vera host to an email server on port 25. The second line with the "*" to the left of its ID is the current connection (on which the STAT command was run). The third line is a connection from a Vera host to an HTD gateway on port 10006. Notice the two Vera connections have different device/service/actions for notification.

### Adapting Plugins/Applications

The proxy is meant to be as transparent as possible. This should make integrating the proxy with existing code fairly straightforward. When using the proxy, there are two big differences to address:

1. How you connect - when using the proxy, you connect to the proxy, not the endpoint, and then once you have the proxy connection, you direct the proxy to connect to the endpoint (by issing the CONN command); from there on, all device communication is the same.
2. How you receive data - you can use the same approaches for reading data you currently use, and tune them to any degree you wish when working with the proxy. For example, if your plugin polls the socket for data periodically, it can continue to do this, it should just additionally respond to its notification action being invoked.

Clever developers will soon recognize that their plugins can continue to operate both with and without the proxy, with just minor code changes.

> rigpapa's strategy in a nutshell: My plugin normally polls for data to receive using `luup.call_delay()` (basically). As part of my integration of the proxy, my connect function tries the proxy first, and then falls back to directly connecting to the endpoint if the proxy connection fails. I keep a boolean _usingProxy_ that tells me which I'm using: *true* for the proxy, *false* for direct connection. If _usingProxy_ is *false*, I continue to schedule my receive function as usual. But if it's *true*, I don't schedule any polling, and I have my action implementation for the proxy's notification call my receive function directly. That's pretty much the meat of it... it's that easy.

Let's start by looking at the initial connection. Here's a typical method for connecting directly to a remote host in the usual way:

```
function connect( ip, port )
    local socket = require "socket"
    local sock = socket.tcp()
    sock:settimeout( 10 )
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
    sock:settimeout( 10 )
    -- Try proxy connection first
    if sock:connect( "127.0.0.1", 2504 ) then
        -- Accepted connection, connect proxy to target and go into echo mode
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

The above `CONN` command is abbreviated for clarity; it would normally include at least a `NTFY` option to specify the device and action (with service ID) to receive notifications of ready data.

### Handling Notifications and Receiving Data

To receive notifications, you just need to define an action in the service your plugin/device default. That's the service ID and action name you provide to the NTFY command or CONN option. Because of the single-threaded nature of Vera and openLuup plugins, it's recommended that you define the implementation of your action as a `<job>` (as opposed to a `<run>`. Your action implementation should read the socket to retrieve its data and handle it. 

As mentioned earlier, if it's possible that your endpoint can send you (very) frequent messages, you may want to consider using the PACE option to reduce the frequency of notifications. This basically "batches up" notifications so that individual datagrams received within the pace period produce just one notification. For example, if PACE=5, any number of datagrams arriving within a five-second period will cause only a single notification. This does not delay notifications--the first notification is sent when the first datagram is received from the remote. It is the follow-on datagrams over the remainder of the five second period that don't get individual notifications. Therefore, your socket read routine should spend an amount of time equal to the pace time waiting for data, to make sure you've received all of the datagrams that arrive during the "quiet period."

### Multiple Connections and the "Pid"

It is possible to have multiple connections from a single plugin/device to/though the proxy if, for example, your plugin/device contacts multiple endpoints. In fact, that's no problem at all. Each connection can even have its own notification action, although in practical terms, this may be more cumbersome than just using a single action to receive all notifications from the proxy. How, in that case, would one distinguish which connection a notification was then for?

The notification action is invoked with a "Pid" parameter, and the value of that parameter is the _pid_ first seen on the proxy's greeting. If you want to keep track of _pids_, you could parse them from the greeting on each connection. The _pid_ is also repeated in the acknowlegement to the CONN command (e.g. `OK CONN pid`), so you can also parse it there. Alternately, if you include a _pid_ at the end of your CONN command's NTFY option (e.g. `CONN host:port NTFY=device/serviceID/action/pid`), the _pid_ you give there is the Pid value you will receive in notifications &mdash; if you set one, it's used in preference to the default one, so no parsing of proxy responses is necessary. It's your choice which method you want to use. Or, you can be (perhaps justifiably) lazy and not worry about it, just check all your sockets when you get a notification for any of them, and leave it at that.

## LICENSE

sockproxyd is offered under GPLv3.
