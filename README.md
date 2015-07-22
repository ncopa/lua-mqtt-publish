# lua-mqtt-publish
 Lua module for simple MQTT connect, publish and disconnect

```lua
publish = require("mqtt.publish")

hostname=arg[1]
port=arg[2]

messages = {
	{ topic = "test/multi1", payload = "data1" },
	{ topic = "test/multi2", payload = "data2" },
	{ topic = "test/multi3", payload = "data3" },
}

publish.multiple(messages, hostname, port)

publish.single("test/single", "datasingle", hostname, port)

```
