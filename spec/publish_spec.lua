require("busted.runner")()

local broker_helper = require("helpers.broker")
local HOST = broker_helper.HOST

describe("mqtt.publish", function()
	local broker, publish

	setup(function()
		broker = broker_helper.start()
	end)

	teardown(function()
		if broker then
			broker:stop()
		end
	end)

	-- number of open file descriptors, to detect leaked clients
	local function open_fds()
		local f = assert(io.popen("ls /proc/" .. require("posix.unistd").getpid() .. "/fd"))
		local n = 0
		for _ in f:lines() do
			n = n + 1
		end
		f:close()
		return n
	end

	before_each(function()
		-- fresh module for every test so defaults, tls and login settings
		-- do not leak between tests
		package.loaded["mqtt.publish"] = nil
		publish = require("mqtt.publish")
	end)

	describe("tls_set", function()
		it("stores the arguments", function()
			publish.tls_set("cafile", "capath", "certfile", "keyfile")
			assert.same({ cafile = "cafile", capath = "capath", certfile = "certfile", keyfile = "keyfile" }, publish.tls)
		end)

		it("accepts a table", function()
			publish.tls_set({ cafile = "ca" })
			assert.same({ cafile = "ca" }, publish.tls)
		end)
	end)

	describe("login_set", function()
		it("stores the credentials", function()
			publish.login_set("user", "pass")
			assert.equal("user", publish.username)
			assert.equal("pass", publish.password)
		end)
	end)

	describe("single", function()
		it("delivers the message", function()
			local sub = broker:subscribe("single/#")
			assert.same({ true }, { publish.single("single/a", "hello", nil, nil, HOST, broker.port) })
			assert.same({ { topic = "single/a", qos = 0, retain = false, payload = "hello" } }, sub:collect(1))
		end)

		for qos = 0, 2 do
			it("delivers with qos " .. qos, function()
				local sub = broker:subscribe("qos/" .. qos)
				assert.is_true(publish.single("qos/" .. qos, "q", qos, false, HOST, broker.port))
				local got = sub:collect(1)
				assert.equal(1, #got)
				assert.equal(qos, got[1].qos)
			end)
		end

		it("sets the retain flag", function()
			assert.is_true(publish.single("retain/a", "kept", 1, true, HOST, broker.port))
			assert.equal("kept", broker:retained("retain/a"))
			-- clean up the retained message
			assert.is_true(publish.single("retain/a", "", 1, true, HOST, broker.port))
			assert.is_nil(broker:retained("retain/a"))
		end)

		it("does not retain by default", function()
			assert.is_true(publish.single("retain/b", "not kept", 1, nil, HOST, broker.port))
			assert.is_nil(broker:retained("retain/b"))
		end)

		it("handles empty and missing payload", function()
			local sub = broker:subscribe("empty/#")
			assert.is_true(publish.single("empty/a", "", 1, false, HOST, broker.port))
			assert.is_true(publish.single("empty/b", nil, 1, false, HOST, broker.port))
			local got = sub:collect(2)
			assert.same({ "empty/a", "" }, { got[1].topic, got[1].payload })
			assert.same({ "empty/b", "" }, { got[2].topic, got[2].payload })
		end)

		it("delivers a large payload", function()
			local sub = broker:subscribe("large")
			local payload = string.rep("0123456789abcdef", 64 * 1024) -- 1 MiB
			assert.is_true(publish.single("large", payload, 1, false, HOST, broker.port))
			assert.equal(payload, sub:collect(1, 5)[1].payload)
		end)

		it("returns promptly after the message is sent", function()
			local start = broker_helper.now()
			assert.is_true(publish.single("fast", "x", 1, false, HOST, broker.port))
			assert.is_true(broker_helper.now() - start < 0.5)
		end)

		it("uses publish.hostname and publish.port defaults", function()
			local sub = broker:subscribe("defaults")
			publish.hostname = HOST
			publish.port = broker.port
			assert.is_true(publish.single("defaults", "d"))
			assert.equal(1, #sub:collect(1))
		end)

		it("uses the given client id", function()
			assert.is_true(publish.single("cid", "x", 1, false, HOST, broker.port, "spec-client-id"))
			local f = assert(io.open(broker.dir .. "/mosquitto.log"))
			local log = f:read("*a")
			f:close()
			assert.truthy(log:find("as spec-client-id", 1, true))
		end)
	end)

	describe("multiple", function()
		it("delivers all messages in order", function()
			local sub = broker:subscribe("multi/#")
			local msgs = {}
			for i = 1, 20 do
				msgs[i] = { topic = "multi/" .. i, payload = "p" .. i, qos = 1 }
			end
			assert.same({ true }, { publish.multiple(msgs, HOST, broker.port) })
			local got = sub:collect(20)
			assert.equal(20, #got)
			for i = 1, 20 do
				assert.same({ "multi/" .. i, "p" .. i }, { got[i].topic, got[i].payload })
			end
		end)

		it("delivers messages with mixed qos", function()
			-- MQTT only guarantees ordering within the same qos level
			local sub = broker:subscribe("mixed/#")
			local msgs, expected = {}, {}
			for i = 1, 12 do
				msgs[i] = { topic = "mixed/" .. i, payload = "p" .. i, qos = i % 3 }
				expected["mixed/" .. i] = i % 3
			end
			assert.is_true(publish.multiple(msgs, HOST, broker.port))
			local got = {}
			for _, m in ipairs(sub:collect(12)) do
				got[m.topic] = m.qos
			end
			assert.same(expected, got)
		end)

		it("does not modify the caller's message list", function()
			local msgs = { { topic = "nomod/1", payload = "a" }, { topic = "nomod/2", payload = "b", qos = 1 } }
			local copy = { { topic = "nomod/1", payload = "a" }, { topic = "nomod/2", payload = "b", qos = 1 } }
			assert.is_true(publish.multiple(msgs, HOST, broker.port))
			assert.same(copy, msgs)
		end)

		it("returns for an empty message list", function()
			assert.is_true(publish.multiple({}, HOST, broker.port))
		end)

		it("raises on invalid topic without leaking the client", function()
			local fds = open_fds()
			assert.has_error(function()
				publish.multiple({ { topic = "ok" }, { topic = "bad/#" } }, HOST, broker.port)
			end, "Invalid input")
			assert.has_error(function()
				publish.multiple({ { payload = "no topic" } }, HOST, broker.port)
			end)
			assert.equal(fds, open_fds())
		end)
	end)

	describe("authentication", function()
		it("succeeds with valid credentials", function()
			publish.login_set(broker_helper.USER, broker_helper.PASSWORD)
			assert.is_true(publish.single("auth", "x", 1, false, HOST, broker.auth_port))
		end)

		it("fails with wrong password", function()
			publish.login_set(broker_helper.USER, "wrong")
			local ok, rc, msg = publish.single("auth", "x", 1, false, HOST, broker.auth_port)
			assert.is_nil(ok)
			assert.is_number(rc)
			assert.is_string(msg)
		end)

		it("fails without credentials", function()
			local ok, rc, msg = publish.single("auth", "x", 1, false, HOST, broker.auth_port)
			assert.is_nil(ok)
			assert.is_number(rc)
			assert.is_string(msg)
		end)

		it("fails for an empty message list", function()
			assert.is_nil((publish.multiple({}, HOST, broker.auth_port)))
		end)
	end)

	describe("tls", function()
		-- without ignore_sigpipe a successful TLS publish kills the test
		-- runner with SIGPIPE (libmosquitto 2.1)
		local it_sigpipe = require("mosquitto").ignore_sigpipe and it or pending

		it_sigpipe("connects with the right CA", function()
			publish.tls_set(broker.ca)
			assert.is_true(publish.single("tls", "x", 1, false, HOST, broker.tls_port))
		end)

		it_sigpipe("authenticates with a client certificate", function()
			publish.tls_set(broker.ca, nil, broker.client_cert, broker.client_key)
			assert.is_true(publish.single("tls", "x", 1, false, HOST, broker.cert_port))
		end)

		it_sigpipe("ignores SIGPIPE", function()
			assert.is_true(publish.single("tls", "x", 1, false, HOST, broker.port))
			local f = assert(io.open("/proc/" .. require("posix.unistd").getpid() .. "/status"))
			local mask = f:read("*a"):match("SigIgn:%s*(%x+)")
			f:close()
			-- SIGPIPE is signal 13, bit 12 in the mask
			assert.equal(1, math.floor(tonumber(mask:sub(-4), 16) / 0x1000) % 2)
		end)


		it("fails with the wrong CA", function()
			publish.tls_set(broker.other_ca)
			assert.is_nil((publish.single("tls", "x", 1, false, HOST, broker.tls_port)))
		end)

		it("fails without client certificate when one is required", function()
			publish.tls_set(broker.ca)
			assert.is_nil((publish.single("tls", "x", 1, false, HOST, broker.cert_port)))
		end)

		it("raises on missing CA file without leaking the client", function()
			local fds = open_fds()
			publish.tls_set("/nonexistent/ca.crt")
			assert.has_error(function()
				publish.single("tls", "x", 1, false, HOST, broker.tls_port)
			end)
			assert.equal(fds, open_fds())
		end)
	end)

	describe("network errors", function()
		it("fails when nothing listens on the port", function()
			local ok, rc, msg = publish.single("x", "x", 0, false, HOST, 1)
			assert.is_nil(ok)
			assert.is_number(rc)
			assert.is_string(msg)
		end)

		it("fails on unresolvable host", function()
			assert.is_nil((publish.single("x", "x", 0, false, "nonexistent.invalid", 1883)))
		end)
	end)
end)
