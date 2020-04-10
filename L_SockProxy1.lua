-- L_SockProxy1.lua, (C) 2020 Patrick H. Rigney, All Rights Reserved

local PLUGIN_NAME =		"SockProxy1"
local PLUGIN_VERSION =	"20101.1135"



local isOpenLuup = luup.openLuup ~= nil
local pluginDevice

lfs = require "lfs"

local MYSID = "urn:toggledbits-com:serviceId:SockProxy1"

local function file_mod( fn )
	return lfs.attributes( fn, "modification" ) or 0
end

local function getInstallPath()
	if not installPath then
		installPath = "/etc/cmh-ludl/" -- until we know otherwise
		if isOpenLuup then
			local loader = require "openLuup.loader"
			if loader.find_file then
				installPath = loader.find_file( "L_SockProxy1.lua" ):gsub( "L_SockProxy1.lua$", "" )
			else
				installPath = "./" -- punt
			end
		end
	end
	return installPath
end

local function getVar( var, dflt )
	local s = luup.variable_get( MYSID, var, pluginDevice ) or dflt
	if "" == s then return dflt end
	return s
end

local function setVar( var, val )
	val = tostring( val or "" )
	local s = getVar( var, nil ) -- default nil
	if val ~= s then
		luup.variable_set( MYSID, var, val, pluginDevice )
	end
	return s -- return old value
end

function reboot()
	os.execute( "sync && sync" )
	os.execute( "/sbin/reboot" )
end

function proxy_check()
	luup.call_delay( 'proxy_check', 300 )
	local socket = require "socket"
	local sock = socket.tcp()
	sock:settimeout( 10 )
	if not sock:connect( "127.0.0.1", 2504 ) then
		setVar( "Status", 0 )
		setVar( "Message", "Down; can't connect" )
	else
		local ans,err = sock:receive("*l")
		if not ans then
			luup.log("SockProxy1: health-check of proxy failed! "..tostring(err), 1)
			setVar( "Status", 0 )
			setVar( "Message", "Down; missed greeting" )
		else
			local ver = ans:match("^OK TOGGLEDBITS%-SOCKPROXY (%d+)")
			if ver then
				if setVar( "Status", 1 ) ~= "1" then
					luup.log("SockProxy1: Proxy is healthy!")
				end
				setVar( "Version", ver )
				setVar( "Message", "Up; healthy" )
			else
				luup.log("SockProxy1: invalid response from proxy: "..tostring(ans), 1)
				setVar( "Status", 0 )
				setVar( "Message", "Down; invalid greeting" )
			end
		end
		sock:shutdown("both")
	end
	sock:close()
end

function startup( pdev )

	pluginDevice = pdev
	luup.log(string.format("Starting %s ver %s", PLUGIN_NAME, PLUGIN_VERSION))
	setVar("Status", 0)
	setVar("Message", "Checking configuration...")

	local ipath = getInstallPath()
	local restart = false

	if isOpenLuup then
		return false, "See README file", PLUGIN_NAME
	elseif file_mod( ipath.."L_SockProxy1.lua" ) > 0 then
		return false, "Invalid install", PLUGIN_NAME
	end

	local selfd = lfs.attributes( ipath.."L_SockProxy1.lua.lzo", "modification" )

	local pkg = ipath.."L_SockProxy1_pkg.lua.lzo"
	local script = ipath .. "sockproxyd.lua"
	if file_mod( pkg ) >= file_mod( script ) then
		luup.log("SockProxy1: refreshing proxy daemon executable",2)
		if os.execute( "pluto-lzo d '" .. pkg .. "' '" .. script .. "'" ) == 0 then
			restart = true
		else
			luup.log("SockProxy1: An error occurred while attempting to uncompress the daemon executable. Please do it manually. The daemon has not been updated.",1)
			return false, "Setup failure 1", PLUGIN_NAME
		end
	end

	local inits = "/etc/init.d/sockproxyd"
	local initd = file_mod( inits )
	if selfd >= initd then
		luup.log("SockProxy1: Writing init script "..inits)
		local f,err = io.open( inits, "w" )
		if not f then
			luup.log("SockProxy1:startup() can't write "..inits..": "..tostring(err),1)
			return false, "Setup failure 2", PLUGIN_NAME
		end
		f:write(([[#!/bin/sh /etc/rc.common
# (C) 2020 Patrick H. Rigney, All Rights Reserved; part of SockProxy
# init script for Vera systems
# https://github.com/toggledbits/sockproxyd

START=80

USE_PROCD=1
PROG=###sockproxyd.lua
LOGFILE=/tmp/sockproxyd.log

start_service () {
        procd_open_instance
        procd_set_param command lua "$PROG" -L "$LOGFILE"
        procd_set_param pidfile /var/run/sockproxyd.pid
        procd_set_param limits core="unlimited"
        procd_close_instance
}
]]):gsub( "%#%#%#", ipath ) )
		f:close()
		os.execute( "rm -f /etc/rc.d/S*sockproxyd" )
	end
	if file_mod( "/etc/rc.d/S80sockproxyd" ) == 0 then
		os.execute( "rm -f /etc/rc.d/S*sockproxyd" ) -- there can be only one
		os.execute( "cd /etc/rc.d/ && ln -s ../init.d/sockproxyd S80sockproxyd" )
		if file_mod( inits ) > 0 and file_mod( "/etc/rc.d/S80sockproxyd" ) > 0 then
			restart = true
		else
			luup.log("SockProxy1: failed to link "..inits..", please do it manually", 1)
			return false, "Setup failure 3", PLUGIN_NAME
		end
	end
	if restart then
		setVar( "Message", "Waiting for system reboot to complete install" )
		luup.call_delay( "reboot", 60, "" )
		luup.log("SockProxy1: System reboot scheduled for 60 seconds!", 2)
		return false, "Reboot! Please Wait!", PLUGIN_NAME
	end
	luup.log("SockProxy1: system configuration checks out OK. First proxy health check will occur shortly.")
	luup.call_delay( 'proxy_check', 5 )
	luup.set_failure( 0, pdev )
	return true, "", PLUGIN_NAME
end
