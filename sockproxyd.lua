--[[
	sockproxyd.lua
	The operative part of the SockProxy plugin for Vera. Implements a pass-through socket
	proxy that receives data from one connection and transmits it to another. More importantly,
	it notifies, via action invocation, a Vera device that data is waiting on the socket.

	Copyright (C) 2020 Patrick H. Rigney, All Rights Reserved

	See https://
--]]

socket = require "socket"

_PLUGIN_NAME = "sockproxyd"
_VERSION = 1 -- version of the protocol, which is what we declare to clients
_BUILD = 20106

DEFAULT_BLOCKSIZE = 2048
DEFAULT_PORT = 2504
DEFAULT_SERVICE = "urn:toggledbits-com:serviceId:SockProxy1"
DEFAULT_ACTION = "HandleReceiveData"
_IDENT = "TOGGLEDBITS-SOCKPROXY" -- Do NOT modify this string, ever.

settings = {
	host={ ip="*", port=DEFAULT_PORT, vera="http://127.0.0.1:3480" },
	direct={}
}

lastid = 0
clients = {}
listeners = {}
sendQueue = {}
debugMode = false
keepGoing = true
logFile = io.stderr

if not unpack then unpack = table.unpack end

timenow = socket.gettime

print = function(...)
	logFile:write( os.date("%x.%X") )
	logFile:write( string.format(".%03d ", math.floor( ( timenow() % 1 ) * 1000 ) ) )
	logFile:write( table.concat( arg, " " ) )
	logFile:write( "\n" )
	logFile:flush()
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
	logFile:write( string.format(".%03d ", math.floor( ( timenow() % 1 ) * 1000 ) ) )
	logFile:write( str )
	logFile:write( "\n" )
	logFile:flush()
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

function readConfig( fn, cf )
	cf = cf or {}
	local f,ferr = io.open( fn, "r" )
	if not f then
		return nil, ferr
	end
	local section = cf
	while true do
		local line = f:read("*l")
		if not line then break end
		line = line:gsub( "^%s+", "" ):gsub( "%s+$", "" )
		if line:match( "%S" ) and not line:match("^;") then
			local s = line:match( "^%[([^%]]+)%]" )
			if s then
				s = s:lower()
				cf[s] = cf[s] or {}
				section = cf[s]
			else
				local val
				s,val = line:match( "^([^=]+)=(.*)" )
				if s then
					section[s:lower()] = val
				else
					section[line:lower()] = true
				end
			end
		end
	end
	f:close()
	return cf
end

function HTTPRequest( url )
	local http = require "socket.http"
	local ltn12 = require "ltn12"

	-- Set up the request table
	local req = {
		url = url,
		source = nil,
		sink = ltn12.sink.null(), -- discard data
		method = "GET",
		headers = { ['connection']="close", ['user-agent']="sockproxyd-".._VERSION },
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
			( (client.lastnotify or 0) + client.notifypace ) <= timenow() then
			table.remove( sendQueue, k )
			sendQueue[e.client] = nil
			if e then
				if client then client.lastnotify = timenow() end
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
		settings.host.vera,
		client.device or -1,
		urlencode( client.service or DEFAULT_SERVICE ),
		urlencode( client.action or DEFAULT_ACTION ),
		urlencode( client.pid or client.id ) )
	table.insert( sendQueue, { client=client.id, request=req } )
	sendQueue[ client.id ] = #sendQueue
end

local function dtime( n )
	n = math.floor( n )
	local t = "m"
	if n >= 6000 then
		n = math.floor( n / 60 )
		t = "h"
	end
	local s = n % 60
	local m = math.floor(n / 60)
	return string.format("%02d%s%02d", m, t, s)
end

function processCONN( client, cmd )
	local rip, rport, rest = cmd:match("^([^:]+):(%d+)%s*(.*)")
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
			client.remotetimeout = tonumber(v) or client.remotetimeout
		elseif k == "BLKS" then
			client.block = tonumber(v) or client.block
		elseif k == "PACE" then
			client.notifypace = tonumber(v) or client.notifypace
		elseif k == "NTFY" then
			local args = split( v, "/" )
			client.device = tonumber( args[1] ) or -1
			client.service = args[2] or DEFAULT_SERVICE
			client.action = args[3] or DEFAULT_ACTION
			client.pid = args[4] or client.pid
		else
			L({level=2,"Client %1 attempted CONN option %1, not supported"}, client.id, opt)
			client.sock:send("ERR CONN Invalid option "..opt.."\n")
			return false
		end
	end
	local remote = socket.tcp()
	remote:settimeout( 5 )
	-- remote:setoption('keepalive', true)
	L("Client %1 from %2 attempting remote to %3:%4", client.id, client.peer, rip, rport)
	local st, err = remote:connect( rip, rport )
	if st then
		client.remote = remote
		client.remotehost = rip .. ":" .. rport
		client.lastremote = timenow()
		client.peertimeout = client.remotetimeout
		D("handleClientData() client %1 now with remote %2:%3", client.id, rip, rport)
		return true
	end
	client.sock:send("ERR CONN "..tostring(err).."\n")
	L("Client %1 connection to %2:%3 failed: %4", client.id, rip, rport, err)
	return false
end

function handleClientData( client, data )
	D("handleClientData(%1,%2)", client, data)
	if client.state == 1 then
		-- Waiting for COMMAND
		client.buffer = ( client.buffer or "" ) .. data
		if not client.buffer:match("\n") then return true end
		data = client.buffer
		client.buffer = nil
		local cmd,rest = data:match("^%s*(%S+)%s*(.*)\n")
		rest = rest or ""
		D("handleClient() client %1 command %2 rest %3", client.id, cmd, rest)
		if cmd == "CONN" then
			-- CONN host:ip
			local st = processCONN( client, rest )
			if st then
				-- Enter ECHO mode
				client.state = 2
				client.sock:send("OK CONN "..client.pid.."\n") -- add pid for confirmation
			end
			return st
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
			local f = "%s%-8s %-2s %-5s|%-5s %-16s %-21s %6s %6s %s\n"
			local l = string.format( f, " ", "ID", "St", "Idle", "Uptim", "Client", "Remote", "#recv", "#xmit", "Notify" )
			client.sock:send( l )
			for _,cl in pairs( clients ) do
				local nt = ( cl.device or -1 ) > 0 and
					( cl.device .. "/" .. ( cl.service or DEFAULT_SERVICE ) .. "/" ..
						( cl.action or DEFAULT_ACTION ) .. "/" .. cl.pid ) or ""
				l = string.format( f,
					( client.id == cl.id ) and "*" or " ",
					cl.id,
					cl.state,
					dtime( timenow()-(cl.lastremote or timenow()) ),
					dtime( timenow()-cl.when ),
					cl.peer or "",
					cl.remotehost or "",
					cl.remote_received or 0,
					cl.remote_sent or 0,
					nt
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
NTFY dev sid action [pid] - Set Luup action request parameters
CONN host:port [key=value ...] - Connect to remote (enters echo mode, must be last command)
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
		-- ECHO mode. We receive data from client and send it to remote.
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
		client.remote:shutdown("both")
		client.remote:close()
		client.remote = nil
	end
	if client.sock then
		client.sock:settimeout(0)
		client.sock:shutdown("both")
		client.sock:close()
		client.sock = nil
	end
end

function handleClient( id )
	D("handleClient(%1)", id)
	local client = clients[id]
	client.lastpeer = timenow()
	while coroutine.yield( client ) do
		local sock = client.sock
		sock:settimeout(0)
		local data,derr,rest = sock:receive( client.block or DEFAULT_BLOCKSIZE )
		if not data then
			if rest and #rest > 0 then
				D("handleClient() peer receive partial %1 %2 bytes (%3)", id, #rest, derr)
				data = rest
			elseif derr ~= "timeout" then
				L("Client %1 peer %2", id, derr)
				break
			end
		end
		-- handle received data on client socket, if any
		if data and #data > 0 then
			client.lastpeer = timenow()
			if not handleClientData( client, data ) then break end
			if derr and derr ~= "timeout" then break end
		end

		-- see if remote has data
		if client.remote then
			client.remote:settimeout(0)
			data,derr,rest = client.remote:receive( client.block or DEFAULT_BLOCKSIZE )
			if not data then
				if rest and #rest > 0 then
					D("Client %1 remote receive partial %2 bytes (%3)", client.id, #rest, derr)
					data = rest
				elseif derr ~= "timeout" then
					L("Client %1 remote %2", client.id, derr)
					break
				end
			end
			if data and #data > 0 then
				D("remote receive %1 bytes", #data)
				client.remote_received = ( client.remote_received or 0 ) + #data
				client.lastremote = timenow()
				sock:send( data )
				if derr and derr ~= "timeout" then break end -- notify will still happen
				notifyClient( client )
			end
		end
	end
	D("handleClient() exiting/closing %1", id)
	notifyClient( client )
	closeClient( client )
	return false
end

-- NB: Vera has 32-bit integers
function nextid()
	local id = math.floor( ( timenow() - 1577854800 ) / 10 )
	if id <= lastid then id = lastid + 1 end
	lastid = id
	return id
end

function main( arg )
	while #arg > 0 do
		local aa = table.remove( arg, 1 )
		if aa == "-a" then
			settings.host.ip = table.remove( arg, 1 ) or settings.host.ip
		elseif aa == "-c" then
			local cf = table.remove( arg, 1 ) or "/usr/local/etc/sockproxyd.cf"
			local st,se = readConfig( cf, settings )
			if not st then error("Can't read config "..cf..": "..se) end
			settings = st
		elseif aa == "-p" then
			settings.host.port = tonumber( table.remove( arg, 1 ) ) or settings.host.port
		elseif aa == "-D" then
			settings.host.debug = true
		elseif aa == "-L" then
			settings.host.log = table.remove( arg, 1 ) or "./sockproxyd.log"
		elseif aa == "-N" or aa == "-V" then
			settings.host.vera = table.remove( arg, 1 ) or settings.host.vera
		else
			error("Unrecognized command line argument: "..aa)
		end
	end

	if settings.host.log and settings.host.log ~= "-" then
		local f,ferr = io.open( settings.host.log, "a" )
		if not f then error(settings.host.log..": "..ferr) end
		logFile = f
	else
		logFile = io.stderr
	end

	debugMode = debugMode or settings.host.debug

	L("Starting sockproxyd version %1 build %2", _VERSION, _BUILD)

	D("settings: %1", settings)

	local server = socket.tcp()
	assert( server:bind( settings.host.ip, settings.host.port ) )
	assert( server:setoption( 'reuseaddr', true ) )
	assert( server:listen( 5 ) )
	assert( server:settimeout(0) )

	listeners = { [server]="!" }

	for loc,v in pairs( settings.direct or {} ) do
		loc = tonumber( loc )
		if loc then
			local s = socket.tcp()
			local st,se = s:bind( settings.host.ip, loc )
			if st then
				s:setoption( 'reuseaddr', true )
				s:listen( 5 )
				s:settimeout( 0 )
				listeners[s] = v
				L("Added listener on %1:%2 for %3", settings.host.ip, loc, v)
			else
				L({level=0,"Can't listen on %1:%2: %3"}, settings.host.ip, loc, se)
			end
		end
	end

	L("Ready to serve at %1:%2", settings.host.ip, settings.host.port)
	while keepGoing do
		-- Wait for something to do.
		-- ??? This list construction is really lazy, but good enough for now. FIXME later!!!
		local clist = {}
		for cl in pairs( listeners ) do
			table.insert( clist, cl )
		end
		for _,cl in pairs( clients ) do
			table.insert( clist, cl.sock )
			if cl.remote then table.insert( clist, cl.remote ) end
		end
		D("select(%1)", clist)
		-- ??? we can do a better job of figuring out timing here, some day. But this is fine for now.
		local ready = socket.select( clist, {}, ( #sendQueue == 0 ) and 5 or 1 )
		if debugMode and next(ready) then D("select() ready=%1", ready) end

		-- Accept from new proxy client?
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
				clients[p] = { id=p, pid=p, peer=c:getpeername(), sock=c, task=co, state=1, peertimeout=30000, when=timenow() }
				coroutine.resume( co, p ) -- start client
			end
		end

		-- Check direct listeners for new connections
		for s,d in pairs( listeners ) do
			if s ~= server and ready[s] then
				local c,cerr = s:accept()
				if not c and cerr ~= "timeout" then
					L({level=2,"accept() error on listener %1: %2"}, d, cerr)
				else
					local p = string.format("L%x", nextid())
					local co = coroutine.create( handleClient )
					clients[p] = { id=p, pid=p, peer=c:getpeername(), sock=c, task=co, state=2, peertimeout=30000, when=timenow() }
					if processCONN( clients[p], d ) then
						coroutine.resume( co, p )
					else
						L({level=1,"Listener failed to connect to %1: %2"}, d, se)
						closeClient( clients[p] )
						clients[p] = nil
					end
				end
			end
		end

		-- Run our clients (all of them)
		local dels = {}
		for id,cl in pairs( clients ) do
			local stopClient = false
			local needService = ready[cl.sock] or ( cl.remote and ready[cl.remote] )
			needService = needService or ( cl.task and coroutine.status( cl.task ) ~= "suspended" )
			if not needService and
				( ( cl.peertimeout or 0 ) > 0 and ( 1000 * ( timenow() - cl.lastpeer ) ) >= cl.peertimeout ) then
				needService = true
				stopClient = true
				L("Client %1 from %2 timed out", id, cl.peer)
			end
			if not needService and cl.remote and
				( ( cl.remotetimeout or 0 ) > 0 and ( 1000 * ( timenow() - cl.lastremote ) ) >= cl.remotetimeout ) then
				needService = true
				stopClient = true
				D("main() client %1 remote timeout", id)
			end
			if needService then
				D("main() connection %1 ready for service, running...", id)
				local status,terr = coroutine.resume( cl.task, not stopClient )
				if not ( status and coroutine.status( cl.task ) == "suspended" ) then
					-- Stop or error exit.
					local s = string.format("ran %s; received %d; sent %d",
						dtime( timenow() - ( cl.when or timenow() ) ),
						cl.remote_received or 0, cl.remote_sent or 0)
					if not status then
						L({level=2,msg="Client %1: %2; "..s}, id, terr)
					else
						L("Client %1 from %2 stopped; "..s, id, cl.peer)
					end
					if cl.sock or cl.remote then
						notifyClient( cl )
						closeClient( cl )
					end
					cl.task = nil -- mark coroutine gone for later deletion
				end
			end
			if not cl.task then
				table.insert( dels, id )
			end
		end
		for _,id in ipairs( dels ) do clients[id] = nil end

		-- Send something, maybe (process the send queue)
		if not next( ready ) then
			handleSendQueue()
		end
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
	L("Closing listeners and host")
	for s in pairs( listeners ) do
		D("closing %1", s)
		s:close()
	end
	return 0
end

local st,err = pcall( main, arg )
if not st then L({level=1,msg="Exiting with status 127: %1"}, err) return 127 end
L("Exiting; status %1", err)
if logFile ~= io.stderr then logFile:close() end
return err
