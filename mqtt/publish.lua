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
			keyfile = keyfile
		}
	end
end

function publish.multiple(msgs, hostname, port, client_id, keepalive)
	local client = mqtt.new(client_id)

	client.ON_CONNECT = function()
		for i=1,#msgs do
			client:publish(msgs[i].topic, msgs[i].payload,
				       msgs[i].qos, msgs[i].retain)
		end
	end

	client.ON_PUBLISH = function()
		if msgs and #msgs > 0 then
			msgs = table.remove(msgs, 1)
		end
		if msgs == nil or #msgs == 0 then
			client:disconnect()
		end
	end

	if publish.tls then
		client:tls_set(publish.tls.cafile, publish.tls.capath,
			publish.tls.certfile, publish.tls.keyfile)
	end
	client:connect(hostname or publish.hostname, port or publish.port,
		       keepalive or publish.keepalive)
	client:loop_forever()
	client:destroy()
end

function publish.single(topic, payload, qos, retain, hostname, port, client_id,
			keepalive)
	return publish.multiple(
		{{ topic=topic, payload=payload, qos=qos, retain=retain }},
		hostname, port, client_id, keepalive
	)
end

return publish
