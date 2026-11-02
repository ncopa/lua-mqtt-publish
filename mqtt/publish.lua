--- @module mosquitto.publish

local mqtt = require("mosquitto")
local publish = {}

function publish.tls_set(cafile, capath, certfile, keyfile)
	if type(cafile) == "table" then
		publish.tls = cafile
	else
		publish.tls = {
			cafile = cafile,
			capath = capath,
			certfile = certfile,
			keyfile = keyfile,
		}
	end
end

function publish.login_set(username, password)
	publish.username = username
	publish.password = password
end

function publish.multiple(msgs, hostname, port, client_id, keepalive)
	-- libmosquitto can trigger SIGPIPE (e.g. on TLS disconnect), which
	-- kills the process. Ignore it while we talk to the broker, if
	-- lua-mosquitto lets us put it back afterwards. An ignored SIGPIPE
	-- would otherwise be inherited by every child process started later.
	local sigpipe = mqtt.ignore_sigpipe and mqtt.restore_sigpipe
	if sigpipe then
		mqtt.ignore_sigpipe()
	end
	local client = mqtt.new(client_id)
	local all_sent = false
	local pending = #msgs
	local fail_rc, fail_msg
	local raised

	client.ON_CONNECT = function(success, rc, msg)
		if not success then
			-- connection refused, e.g. bad credentials. The broker closes
			-- the connection and ON_DISCONNECT stops the loop.
			fail_rc, fail_msg = rc, msg
			return
		end
		if pending == 0 then
			-- nothing to publish so ON_PUBLISH will never trigger disconnect
			all_sent = true
			client:disconnect()
			return
		end
		for i = 1, #msgs do
			-- don't let errors unwind through the C library's loop. Save it
			-- and raise it once the client is cleaned up.
			local ok, e = pcall(client.publish, client, msgs[i].topic, msgs[i].payload, msgs[i].qos, msgs[i].retain)
			if not ok then
				raised = e
				client:disconnect()
				return
			end
		end
	end

	client.ON_PUBLISH = function()
		pending = pending - 1
		if pending <= 0 then
			all_sent = true
			client:disconnect()
		end
	end

	client.ON_DISCONNECT = function(success, rc, msg)
		if not all_sent and not fail_rc then
			fail_rc, fail_msg = rc, msg
		end
		client:disconnect() -- in case server does the disconnect
	end

	local ok, status, err, errmsg = pcall(function()
		if publish.tls then
			client:tls_set(publish.tls.cafile, publish.tls.capath, publish.tls.certfile, publish.tls.keyfile)
		end
		if publish.username then
			client:login_set(publish.username, publish.password)
		end

		local status, err, errmsg =
			client:connect(hostname or publish.hostname, port or publish.port, keepalive or publish.keepalive)
		if status then
			-- After a clean disconnect, loop_forever runs one more iteration that
			-- waits the full select timeout (1s by default) before it returns.
			-- Use a short timeout so publishing does not stall for a second.
			status, err, errmsg = client:loop_forever(10)
		end
		return status, err, errmsg
	end)
	-- free the client now instead of waiting for the garbage collector. It
	-- holds sockets that would otherwise leak into child processes.
	client:destroy()
	-- after destroy, which may still write a TLS close_notify
	if sigpipe then
		mqtt.restore_sigpipe()
	end
	if not ok then
		error(status, 0)
	end
	if raised then
		error(raised, 0)
	end
	if status and not all_sent then
		status, err, errmsg = nil, fail_rc, fail_msg
	end
	return status, err, errmsg
end

function publish.single(topic, payload, qos, retain, hostname, port, client_id, keepalive)
	return publish.multiple(
		{ { topic = topic, payload = payload, qos = qos, retain = retain } },
		hostname,
		port,
		client_id,
		keepalive
	)
end

return publish
