-- Test helper: runs a private mosquitto broker with a set of listeners
-- (anonymous, password auth, TLS, TLS with client certificates) and
-- provides subscribers that can verify what the broker actually received.

local socket = require("posix.sys.socket")
local ptime = require("posix.time")
local unistd = require("posix.unistd")

local M = {}

M.HOST = "127.0.0.1"
M.USER, M.PASSWORD = "testuser", "testpass"

local function sh(cmd)
	local ok = os.execute(cmd)
	if ok ~= true and ok ~= 0 then
		error("command failed: " .. cmd, 2)
	end
end

local function readall(cmd)
	local f = assert(io.popen(cmd))
	local out = f:read("*a")
	f:close()
	return out
end

local function writefile(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

--- Monotonic time in seconds.
function M.now()
	local t = ptime.clock_gettime(ptime.CLOCK_MONOTONIC)
	return t.tv_sec + t.tv_nsec / 1e9
end

local function sleep_ms(ms)
	ptime.nanosleep({ tv_sec = math.floor(ms / 1000), tv_nsec = (ms % 1000) * 1e6 })
end

local function tcp_socket()
	return assert(socket.socket(socket.AF_INET, socket.SOCK_STREAM, 0))
end

local function free_port()
	local fd = tcp_socket()
	assert(socket.bind(fd, { family = socket.AF_INET, addr = M.HOST, port = 0 }))
	local port = assert(socket.getsockname(fd)).port
	unistd.close(fd)
	return port
end

local function port_open(port)
	local fd = tcp_socket()
	local ok = socket.connect(fd, { family = socket.AF_INET, addr = M.HOST, port = port })
	unistd.close(fd)
	return ok == 0
end

local function gen_certs(dir)
	local q = " >/dev/null 2>&1"
	local key = "-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes"
	writefile(dir .. "/server.ext", "subjectAltName=DNS:localhost,IP:127.0.0.1\n")
	sh(("cd %s && openssl req -x509 %s -keyout ca.key -out ca.crt -days 1 -subj /CN=test-ca%s"):format(dir, key, q))
	for _, name in ipairs({ "server", "client" }) do
		sh(("cd %s && openssl req %s -keyout %s.key -out %s.csr -subj /CN=%s%s"):format(dir, key, name, name, name, q))
		sh(
			("cd %s && openssl x509 -req -in %s.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -out %s.crt %s%s"):format(
				dir,
				name,
				name,
				name == "server" and "-extfile server.ext" or "",
				q
			)
		)
	end
	-- a second CA that did not sign the server cert
	sh(("cd %s && openssl req -x509 %s -keyout other-ca.key -out other-ca.crt -days 1 -subj /CN=other-ca%s"):format(dir, key, q))
end

local Broker = {}
Broker.__index = Broker

--- Start a broker. Returns an object with the ports and file paths.
function M.start()
	local self = setmetatable({}, Broker)
	self.dir = readall("mktemp -d"):gsub("%s+$", "")
	local d = self.dir
	self.port, self.auth_port, self.tls_port, self.cert_port = free_port(), free_port(), free_port(), free_port()
	self.ca, self.other_ca = d .. "/ca.crt", d .. "/other-ca.crt"
	self.client_cert, self.client_key = d .. "/client.crt", d .. "/client.key"

	gen_certs(d)
	sh(("mosquitto_passwd -b -c %s/passwd %s %s >/dev/null"):format(d, M.USER, M.PASSWORD))
	sh(("chmod 600 %s/passwd"):format(d))

	local tls = ("cafile %s\ncertfile %s/server.crt\nkeyfile %s/server.key\n"):format(self.ca, d, d)
	writefile(
		d .. "/mosquitto.conf",
		table.concat({
			"per_listener_settings true",
			"persistence false",
			-- queue QoS 0 for offline persistent subscribers so tests can
			-- collect them afterwards
			"queue_qos0_messages true",
			"pid_file " .. d .. "/mosquitto.pid",
			"log_dest file " .. d .. "/mosquitto.log",
			("listener %d %s\nallow_anonymous true"):format(self.port, M.HOST),
			("listener %d %s\nallow_anonymous false\npassword_file %s/passwd"):format(self.auth_port, M.HOST, d),
			("listener %d %s\nallow_anonymous true\n%s"):format(self.tls_port, M.HOST, tls),
			("listener %d %s\nallow_anonymous true\nrequire_certificate true\n%s"):format(self.cert_port, M.HOST, tls),
			"",
		}, "\n")
	)

	-- startup warnings (e.g. deprecated options in newer mosquitto) go to stderr
	sh(("mosquitto -d -c %s/mosquitto.conf 2>%s/stderr.log"):format(d, d))
	for _ = 1, 100 do
		if port_open(self.port) and port_open(self.cert_port) then
			return self
		end
		sleep_ms(50)
	end
	local f = io.open(d .. "/stderr.log")
	local msg = f and f:read("*a") or ""
	if f then
		f:close()
	end
	self:stop()
	error("mosquitto did not start: " .. msg)
end

function Broker:stop()
	local f = io.open(self.dir .. "/mosquitto.pid")
	if f then
		local pid = f:read("*n")
		f:close()
		if pid then
			os.execute("kill " .. pid)
		end
	end
	os.execute("rm -rf '" .. self.dir .. "'")
end

local client_counter = 0

-- Run a lua-mosquitto client until stop() is called from a callback or
-- the timeout expires. A hand rolled loop is used instead of loop_forever,
-- which waits a full select timeout after disconnecting.
local function run_client(self, clean_session, client_id, setup, timeout)
	local mqtt = require("mosquitto")
	local client = mqtt.new(client_id, clean_session)
	local done = false
	local function stop()
		if not done then
			done = true
			client:disconnect()
		end
	end
	setup(client, stop)
	client.ON_DISCONNECT = stop
	assert(client:connect(M.HOST, self.port))
	local deadline = M.now() + (timeout or 2)
	while not done and M.now() < deadline do
		client:loop(10)
	end
	if not done then
		client:disconnect()
	end
	client:loop(10)
	client:destroy()
	return done
end

--- Create a persistent subscription on the anonymous listener. Messages
--- published after this call are queued by the broker and can be fetched
--- with collect(), so there is no race between subscriber and publisher.
function Broker:subscribe(topic)
	client_counter = client_counter + 1
	local client_id = "spec-sub-" .. client_counter
	assert(run_client(self, false, client_id, function(client, stop)
		client.ON_CONNECT = function()
			client:subscribe(topic, 2)
		end
		client.ON_SUBSCRIBE = stop
	end))
	return {
		--- Fetch n queued messages, waiting at most `timeout` seconds.
		--- Returns a list of { topic=, qos=, retain=, payload= }.
		collect = function(_, n, timeout)
			local msgs = {}
			run_client(self, false, client_id, function(client, stop)
				client.ON_MESSAGE = function(_, t, payload, qos, retain)
					msgs[#msgs + 1] = { topic = t, qos = qos, retain = retain, payload = payload or "" }
					if #msgs >= n then
						stop()
					end
				end
			end, timeout)
			return msgs
		end,
	}
end

--- Read the retained message for a topic, or nil.
function Broker:retained(topic)
	client_counter = client_counter + 1
	-- retained messages are sent right after SUBACK, so once a marker
	-- message published after SUBACK arrives, all retained have arrived.
	local marker = "spec-marker/" .. client_counter
	local payload
	assert(run_client(self, true, nil, function(client, stop)
		client.ON_CONNECT = function()
			client:subscribe(topic, 0)
		end
		local subacks = 0
		client.ON_SUBSCRIBE = function()
			subacks = subacks + 1
			if subacks == 1 then
				client:subscribe(marker, 0)
			else
				client:publish(marker, "", 0)
			end
		end
		client.ON_MESSAGE = function(_, t, p, _, retain)
			if t == marker then
				stop()
			elseif retain then
				payload = p or ""
			end
		end
	end))
	return payload
end

return M
