--[[
	sockproxyd.lua
	The operative part of the SockProxy plugin for Vera. Implements a pass-through socket
	proxy that receives data from one connection and transmits it to another. More importantly,
	it notifies, via action invocation, a Vera device that data is waiting on the socket.
	And that, in fact, is the entire reason it exists. Luup cannot block, and therefore cannot
	yield where blocking I/O is required. The typical alternative, then, is polling the socket
	with a low or zero timeout to see if data is waiting, but this always causes lags in response,
	and always results in excess labor when no data is waiting--a high percentage of the time.
	With SockProxy in place, the plugin need not poll, but rather just read when the notification
	action is invoked. The proxy can manage multiple connections efficiently, so one running
	instance of the proxy should be sufficient to serve any reasonable number of plugins. It is not
	necessary (and not advised) to go proxy-per-plugin.

	Using the Proxy
	---------------
	When first connecting to the proxy, it is in "setup mode". In this mode, a small set of
	commands can be sent:
		RTIM ms					Receive timeout in milliseconds. If data is not received from the
								remote for longer than this period, the remote is disconnected. The
								default is 0, meaning no timeout is enforced.
		BLKS nbytes				Set the network block size to nbytes. The default is DEFAULT_BLOCKSIZE. Messages
								larger than the network block size are received nbytes chunks. It is
								usually not necessary to change this.
		NTFY dev sid act pid	Set the device, serviceID, and action to be used for notification
								of waiting receive data. If not used, no notification is invoked.
								The optional "pid" can be used as an identifier for each connection
								if a client device has multiple connections through the proxy (i.e.
								it tells you which connection has available data).
		PACE seconds			Limits the pace with which received-data notifications are sent
								to not more than once every "seconds" seconds. Default: 0, waiting
								received sends an immediate notification. If a number of datagrams
								are received in a short time, this can result in the proxy "spamming"
								the plugin/device. Setting the frequency higher prevents this, but
								then requires the plugin/device to scan for further data for an equal
								period of time. That is, if the pace is 2 seconds, the plugin should
								loop attempting to read data for 2 seconds (at least) when notified,
								in case more data comes in during the notification pause.
		CONN host:port			Connects (TCP) to host:port, and enters "echo mode". This should
								always be the last setup command issued; it is not possible to issue
								other setup commands after connecting to the remote host.

	When a host first connects to the proxy, the initial greeting is sent. This greeting is always
	"OK TOGGLEDBITS-SOCKPROXY n", where N is the integer version number of the proxy. If your plug-
	in can work with different versions of the proxy, you can parse out the version number. The
	host can then issue any necessary setup commands, and end with the CONN command to connect the
	remote host and enter echo mode.

	Once in echo mode, the proxy passes data between the client connection (between the Vera device
	and the proxy) and the remote connection (between the proxy and the other endpoint). This con-
	tinues until either end closes the connection or an error occurs. Closure of connections is al-
	ways symmetrical: if the remote closes, the client closes; if the client closes, the remote
	closes. This assures that a client is not communicating to nothing, and that the proxy behaves
	as much like a direct connection as possible. This means that the proxy should be transparent
	to WSAPI, etc.

	The proxy's setup mode includes a couple of commands to help humans that connect to it:
		STAT			Shows the status of all connections the proxy is managing.
		CAPA			Shows the capabilities of this version of the proxy (also machine-readable)
		QUIT			Disconnect the current connection from the proxy.
		STOP			Close all connections and stop the proxy daemon.
		HELP			Print command help.

	Starting sockproxyd
	-------------------
	The daemon is meant to be started at system startup (e.g. from /etc/init.d on legacy Veras).
	The following command line options are supported:
		-a address		The address on which to bind (default: *, all addresses/interfaces)
		-p port			The port to listen on for proxy connections (default: DEFAULT_PORT)
		-L logfile		The log file to use
		-V url			The base URL for reaching the Luup system (default: http://127.0.0.1:3480)
		-D				Debug mode
--]]

socket = require "socket"

_PLUGIN_NAME = "sockproxyd"
_VERSION = 1 -- version of the protocol, which is what we declare to clients
_IDENT = "TOGGLEDBITS-SOCKPROXY"

DEFAULT_BLOCKSIZE = 2048
DEFAULT_PORT = 2504
DEFAULT_SERVICE = "urn:toggledbits-com:serviceId:SockProxy1"
DEFAULT_ACTION = "HandleReceiveData"

ip = "*"
port = DEFAULT_PORT
vera = "http://127.0.0.1:3480"
lastid = 0
clients = {}
sendQueue = {}
debugMode = false
keepGoing = true
logFile = io.stderr

if not unpack then unpack = table.unpack end

print = function(...)
	logFile:write( os.date("%x.%X") )
	logFile:write( string.format(".%03d ", math.floor( ( socket.gettime() % 1 ) * 1000 ) ) )
	logFile:write( table.concat( arg, " " ) )
	logFile:write( "\n" )
end

function dump(t, seen)
	if t == nil then return "nil" end
	seen = seen or {}
	local sep = ""
	local str = "{ "
	for k,v in pairs(t) do
		local val
		if type(v) == "table" then
			if seen[v] then val = "(recursion)"
			else
				seen[v] = true
				val = dump(v, seen)
			end
		elseif type(v) == "string" then
			val = string.format("%q", v)
		elseif type(v) == "number" and (math.abs(v-os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. tostring(k) .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

function L(msg, ...) -- luacheck: ignore 212
	local str
	local level = defaultLogLevel or 50
	if type(msg) == "table" then
		str = tostring(msg.prefix or _PLUGIN_NAME) .. ": " .. tostring(msg.msg or msg[1])
		level = msg.level or level
	else
		str = _PLUGIN_NAME .. ": " .. tostring(msg)
	end
	str = string.gsub(str, "%%(%d+)", function( n )
			n = tonumber(n, 10)
			if n < 1 or n > #arg then return "nil" end
			local val = arg[n]
			if type(val) == "table" then
				return dump(val)
			elseif type(val) == "string" then
				return string.format("%q", val)
			elseif type(val) == "number" and math.abs(val-os.time()) <= 86400 then
				return tostring(val) .. "(" .. os.date("%x.%X", val) .. ")"
			end
			return tostring(val)
		end
	)
	logFile:write( string.format("%02d ", level % 100 ) )
	logFile:write( os.date("%x.%X") )
	logFile:write( string.format(".%03d ", math.floor( ( socket.gettime() % 1 ) * 1000 ) ) )
	logFile:write( str )
	logFile:write( "\n" )
--[[ ???dev if level <= 2 then local f = io.open( "/etc/cmh-ludl/Reactor.log", "a" ) if f then f:write( str .. "\n" ) f:close() end end --]]
	if level <= 1 then if debug and debug.traceback then print( debug.traceback() ) end if level <= 0 then error(str, 2) end end
end

function D(msg, ...)
	if debugMode then
		local inf = debug and debug.getinfo(2, "Snl") or {}
		L( { msg=msg,
			prefix=(_PLUGIN_NAME .. "(" ..
				(inf.name or string.format("<func@%s>", tostring(inf.linedefined or "?"))) ..
				 ":" .. tostring(inf.currentline or "?") .. ")") }, ... )
	end
end

assert = function( c, m )
	if not c then L{level=1,msg=m or "Assertion failed"} error(m or "Assertion failed!") end
end

-- An assert() that only functions in debug mode
function DA(cond, m, ...)
	if cond or not debugMode then return end
	L({level=0,msg=m or "Assertion failed!"}, ...)
	error("assertion failed") -- should be unreachable
end

function split( str, pat )
	local res = {}
	pat = pat or ","
	str = string.gsub( str or "", "([^"..pat.."]*)"..pat, function( m ) table.insert( res, m ) return "" end )
	if str ~= "" then table.insert( res, str ) end
	return res
end

function urlencode( s )
	return string.gsub( tostring( s or ""), "[^A-Za-z0-9_.~-]", function( c )
		return string.format( "%%%02x", string.byte( c ) )
	end )
end

function HTTPRequest( url )
	local http = require "socket.http"
	-- local ltn12 = require "ltn12"

	-- Set up the request table
	local req = {
		url = url,
		source = nil,
		sink = nil, -- discard data
		method = "GET",
		headers = { ['connection']="close", ['user-agent']="sockproxyd ".._VERSION },
		redirect = false
	}

	-- Make the request.
	D("HTTPRequest() request %1", req)
	http.TIMEOUT = 5 -- Not going to spend a lot of time waiting
	local respBody, httpStatus, rh, st = http.request(req)
	D("HTTPRequest() response %1, %2, %3, %4", respBody, httpStatus, rh, st)
	if httpStatus == 401 then
		L({level=2,msg="Notification response indicates that service is not defined for the device. Request URL: %1"}, url)
	end

	-- We don't care about the response.
	return
end

-- Send one notification for the first available client
function handleSendQueue()
	-- Find the first eligible message
	local k = 1
	while sendQueue[k] do
		local e = sendQueue[k]
		D("handleSendQueue() considering %1 %2", k, e)
		local client = clients[e.client]
		-- At this point, the client or remote may have closed and no longer exists, so be careful!
		-- We still want to send the notification, as this gives the plugin/client the opportunity
		-- to recognize that the connection has closed (when it tries to receive()).
		if not client or
			(client.notifypace or 0) == 0 or
			( (client.lastnotify or 0) + client.notifypace ) <= socket.gettime() then
			local e = table.remove( sendQueue, k )
			sendQueue[e.client] = nil
			if e then
				if client then client.lastnotify = socket.gettime() end
				HTTPRequest( e.request )
			end
			return
		end
		k = k + 1
	end
end

function notifyClient( client )
	D("notifyClient(%1)", client)
	if (client.device or -1) < 0 or sendQueue[ client.id ] then
		-- No notifcations for this client, or already queued
		return
	end
	local req = string.format(
		[[%s/data_request?id=action&output_format=json&DeviceNum=%s&serviceId=%s&action=%s&Pid=%s]],
		vera,
		client.device or -1,
		urlencode( client.service or DEFAULT_SERVICE ),
		urlencode( client.action or DEFAULT_ACTION ),
		urlencode( client.pid or client.id ) )
	table.insert( sendQueue, { client=client.id, request=req } )
	sendQueue[ client.id ] = #sendQueue
end

function handleClientData( client, data )
	D("handleClientData(%1,%2)", client, data)
	if client.state == 1 then
		-- Waiting for mode
		client.buffer = ( client.buffer or "" ) .. data
		if not client.buffer:match("\n") then return true end
		data = client.buffer
		client.buffer = nil
		local cmd,rest = data:match("^%s*(%S+)%s*(.*)\n")
		rest = rest or ""
		D("handleClient() client %1 command %2 rest %3", id, cmd, rest)
		if cmd == "CONN" then
			-- CONN host:ip
			local rip, rport, rest = rest:match("^([^:]+):(%d+)%s*(.*)")
			rest = rest or ""
			if not rip then
				client.sock:send("ERR CONN Invalid host:port\n")
				return false
			end
			rport = tonumber( rport ) or 80
			-- Handle options
			local opts = split( rest:gsub("^ +","") , " " )
			for _,opt in ipairs( opts ) do
				local k,v = opt:match( "^([^=]+)=(.*)" )
				if k == "RTIM" then
					client.remotetimeout = tonumber(k) or client.remotetimeout
				elseif k == "PACE" then
					client.notifypace = tonumber(k) or client.notifypace
				elseif k == "NTFY" then
					local args = split( v, "/" )
					client.device = tonumber( args[1] ) or -1
					client.service = args[2] or DEFAULT_SERVICE
					client.action = args[3] or DEFAULT_ACTION
					client.pid = args[4] or client.pid
				else
					L({level=2,"Client %1 attempted CONN option %1, not supported"}, id, opt)
					client.sock:send("ERR CONN Invalid option "..opt.."\n")
					return false
				end
			end
			local remote = socket.tcp()
			remote:settimeout(5)
			-- remote:setoption('keepalive', true)
			L("Client %1 from %2 attempting remote to %3:%4", client.id, client.peer, rip, rport)
			local st, err = remote:connect( rip, rport )
			if st then
				client.remote = remote
				client.remotehost = rip .. ":" .. rport
				client.lastremote = socket.gettime()
				client.sock:send("OK CONN "..client.pid.."\n") -- add pid for confirmation
				client.state = 2
				client.peertimeout = client.remotetimeout
				D("handleClientData() client %1 now with remote %2:%3", client.id, rip, rport)
				return true
			end
			client.sock:send("ERR CONN "..tostring(err).."\n")
			L("Client %1 connection to %2:%3 failed: %4", client.id, rip, rport, err)
			return false
		elseif cmd == "NTFY" then
			-- NTFY device service action pid
			local dev,service,action,pid = unpack( split( rest, " " ) )
			client.device = tonumber( dev ) or -1
			client.service = service -- nil OK
			client.action = action -- nil OK
			client.pid = pid or client.pid
			client.sock:send("OK NTFY\n")
			return true
		elseif cmd == "STAT" then
			-- STAT(US)
			local f = "%s%-16s %-2s %-16s %-16s %srx/%stx %s.%s/%s %s\n"
			local l = string.format( f, " ", "ID", "St", "Client", "Remote", "-", "-", "dev", "sid", "act", "pid" )
			client.sock:send( l )
			for _,cl in pairs( clients ) do
				l = string.format( f,
					( client.id == cl.id ) and "*" or " ",
					cl.id,
					cl.state,
					cl.peer or "",
					cl.remotehost or "",
					cl.remote_received or 0,
					cl.remote_sent or 0,
					cl.device or 0,
					cl.service or "",
					cl.action or "",
					cl.pid
					)
				client.sock:send( l )
			end
			client.peertimeout = 6000000 -- stays long time
			return true
		elseif cmd == "BLKS" then
			-- BLKS nbytes
			local s = tonumber( rest )
			if s and s > 0 then
				client.block = s
				client.sock:send("OK BLKS\n")
				return true
			end
			client.sock:send("ERR BLKS Invalid block size\n")
			return false
		elseif cmd == "RTIM" then
			-- RTIM milliseconds
			local s = tonumber( rest )
			if s and s >= 0 then
				client.remotetimeout = s > 0 and s or nil
				client.sock:send("OK RTIM\n")
				return true
			end
			client.sock:send("ERR RTIM Invalid timeout\n")
			return false
		elseif cmd == "PACE" then
			-- PACE seconds
			local s = tonumber( rest )
			if s and s >= 0 then
				client.notifypace = s > 0 and s or nil
				client.sock:send("OK PACE\n")
				return true
			end
		elseif cmd == "HELP" then
			client.sock:send( [[STAT - Status
HELP - This text
QUIT - Disconnect
STOP - Shut down proxy
CAPA - Capabilities
RTIM n - Remote receive timeout n milliseconds (default 0=no timeout)
PACE n - Limit pace of receive data notifications (default 0=no pacing)
BLKS n - Set max packet size to n (default DEFAULT_BLOCKSIZE)
NTFY dev sid action pid - Set Luup action request parameters
CONN host:port - Connect to remote (enters echo mode, must be last command)
]] )
			return true
		elseif cmd == "CAPA" then
			client.sock:send("OK CAPA BLKS RTIM NTFY CONN\n")
			return true
		elseif cmd == "QUIT" then
			client.sock:send( "OK QUIT\n")
			return false
		elseif cmd == "STOP" then
			client.sock:send( "OK STOP\n")
			keepGoing = false
			return true
		else
			client.sock:send("ERR INVALID COMMAND\n")
			return false
		end
	elseif client.state == 2 then
		-- Echo state. We receive data from client and send it to remote.
		client.remote:send( data )
		client.remote_sent = (client.remote_sent or 0) + #data
		D("handleClientData() remote -> %1", data)
		return true
	end
	D("handleClientData() invalid state")
	return false
end

function closeClient( client )
	D("closeClient(%1)", client.id)
	if client.remote then
		client.remote:settimeout(0)
		while client.remote:receive( 1 ) do end
		client.remote:shutdown("both")
		client.remote:close()
		client.remote = nil
	end
	if client.sock then
		client.sock:settimeout(0)
		while client.sock:receive( 1 ) do end
		client.sock:shutdown("both")
		client.sock:close()
		client.sock = nil
	end
end

function handleClient( id )
	D("handleClient(%1)", id)
	local client = clients[id]
	client.lastpeer = socket.gettime()
	while coroutine.yield( client ) do
		local sock = client.sock
		sock:settimeout(0)
		local data,derr,rest = sock:receive( client.block or DEFAULT_BLOCKSIZE )
		if not data then
			if derr ~= "timeout" then
				D("handleClient() receive %1 %2 %3 bytes", id, derr, #rest)
				break
			end
			-- Timeout, maybe with partial data
			data = rest or ""
			if #data > 0 then
				D("handleClient() receive %1 [timeout] %2 bytes", id, #data)
				client.lastpeer = socket.gettime()
			end
		else
			D("handleClient() receive %1 [data] %2 bytes", id, #data)
			client.lastpeer = socket.gettime()
		end
		-- handle received data on client socket, if any
		if #data > 0 then
			if not handleClientData( client, data ) then break end
		end

		-- see if remote has data
		if client.remote then
			client.remote:settimeout(0)
			data,derr,rest = client.remote:receive( client.block or DEFAULT_BLOCKSIZE )
			if data and #data > 0 then
				D("remote receive %1 bytes", #data)
				client.remote_received = ( client.remote_received or 0 ) + #data
				client.lastremote = socket.gettime()
				sock:send( data )
				notifyClient( client )
			elseif derr == "timeout" then
				data = rest or ""
				if #data > 0 then
					D("remote receive %1 bytes (partial)", #data)
					client.remote_received = ( client.remote_received or 0 ) + #data
					client.lastremote = socket.gettime()
					sock:send( data )
					notifyClient( client )
				end
			else
				L("Client %1 remote %2 %3", id, client.remotehost, derr)
				break
			end
		end
	end
	D("handleClient() exiting/closing %1", id)
	notifyClient( client )
	closeClient( client )
	return false
end

function nextid()
	local id = math.floor( socket.gettime() * 1000 )
	if id <= lastid then id = lastid + 1 end
	lastid = id
	return id
end

function main( arg )
	while #arg > 0 do
		local aa = table.remove( arg, 1 )
		if aa == "-a" then
			ip = table.remove( arg, 1 ) or ip
		elseif aa == "-p" then
			port = tonumber( table.remove( arg, 1 ) ) or port
		elseif aa == "-D" then
			debugMode = true
		elseif aa == "-L" then
			local log = table.remove( arg, 1 ) or "./sockproxyd.log"
			local f,ferr = io.open( log, "a" )
			if not f then error(logName..": "..ferr) end
			logFile = f
		elseif aa == "-V" then
			vera = table.remove( arg, 1 ) or vera
		else
			error("Unrecognized command line argument: "..aa)
		end
	end

	local server = socket.tcp()
	assert( server:bind( ip, port ) )
	assert( server:setoption( 'reuseaddr', true ) )
	assert( server:listen( 5 ) )
	assert( server:settimeout(0) )

	L("Ready to serve at %1:%2", ip, port)
	while keepGoing do
		-- Wait for something to do.
		local clist = { server }
		for _,cl in pairs( clients ) do
			table.insert( clist, cl.sock )
			if cl.remote then table.insert( clist, cl.remote ) end
		end
		-- D("select(%1)", clist)
		-- ??? we can do a better job of figuring out timing here, some day. But this is fine.
		local ready = socket.select( clist, {}, ( #sendQueue == 0 ) and 5 or 1 )
		if debugMode and next(ready) then D("select() ready=%1", ready) end

		-- Accept from new client?
		if ready[server] then
			D("main() server socket on ready list, accepting new connection")
			local c,cerr = server:accept()
			if not c and cerr ~= "timeout" then
				L({level=1,"accept() error %1"}, cerr)
				break
			elseif c then
				-- Set up new client
				local p = string.format("%x", nextid())
				assert( not clients[p], "BUG: Client with ID "..p.." already exists!" )
				assert( c:setoption( 'tcp-nodelay', true ) )
				L("New connection from %1 id %2", c:getpeername(), p)
				c:send(string.format("OK %s %s %s\n", _IDENT, _VERSION, p))
				local co = coroutine.create( handleClient )
				clients[p] = { id=p, pid=p, peer=c:getpeername(), sock=c, task=co, state=1, peertimeout=30000 }
				coroutine.resume( co, p ) -- start client
			end
		end

		-- Run our clients (all of them)
		local dels = {}
		for id,cl in pairs( clients ) do
			local stopClient = false
			local needService = ready[cl.sock] or ( cl.remote and ready[cl.remote] )
			needService = needService or ( cl.task and coroutine.status( cl.task ) ~= "suspended" )
			if not needService and
				( ( cl.peertimeout or 0 ) > 0 and ( 1000 * ( socket.gettime() - cl.lastpeer ) ) >= cl.peertimeout ) then
				needService = true
				stopClient = true
				L("Client %1 from %2 timed out", id, cl.peer)
			end
			if not needService and cl.remote and
				( ( cl.remotetimeout or 0 ) > 0 and ( 1000 * ( socket.gettime() - cl.lastremote ) ) >= cl.remotetimeout ) then
				needService = true
				stopClient = true
				D("main() client %1 remote timeout", id)
			end
			if needService then
				D("main() connection %1 ready for service, running...", id)
				local status,terr = coroutine.resume( cl.task, not stopClient )
				if not ( status and coroutine.status( cl.task ) == "suspended" ) then
					-- Stop or error exit.
					if not status then
						L({level=2,msg="Client %1: %2"}, id, terr)
					else
						L("Client %1 from %2 stopped", id, cl.peer)
					end
					notifyClient( cl )
					closeClient( cl )
					cl.task = nil -- mark coroutine gone for later deletion
				end
			end
			if not cl.task then
				table.insert( dels, id )
			end
		end
		for _,id in ipairs( dels ) do clients[id] = nil end

		-- Send something, maybe
		handleSendQueue()
	end

	L{level=2, msg="Main loop exit; closing clients"}
	while true do
		local cl = next( clients )
		if not cl then break end
		cl = clients[cl]
		if cl.task and coroutine.status( cl.task ) == "suspended" then
			local st,err = coroutine.resume( cl.task, false )
			if not st then L({level=1,"Close failed: %1"},err) end
		else
			clients[cl.id] = nil
		end
	end
	L("Closing proxy server")
	server:close()
	return 0
end

return main( arg )
