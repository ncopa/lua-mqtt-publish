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

publish.single("test/single", "datasingle", nil, nil, hostname, port)

-- set default hostname and port
publish.hostname = hostname
publish.port = port

publish.single("test/single", "second datasingle")

```

## Dependencies

Depends on [lua-mosquitto](https://github.com/flukso/lua-mosquitto).

## Functions

### tls_set(cafile, capath, certfile, keyfile)

Set TLS options to be used for encrypted connection.

Parameter | Description
----------|------------
cafile    | Path to a file containing trusted CA certificates.
capath    | path to a directory containing trusted CA certificates.
certfile  | Client certificate for authentication.
keyfile   | Client private key for authentication.


### multiple(msgs, hostname, port, client_id, keepalive)

Connect to host and send a a list of messages. Disconnect when all messages are sent.

Parameter | Description
----------|------------
msgs      | Array with messages. Each message has the fields:`topic`, `payload`, `qos` and `retain`. The field `topic` is mandatory, the rest are optional.
hostname  | Hostname of the broker. _localhost_ will be used if not specified.
port      | The TCP port number to use for connection. _1883_ if not specified.
client_id | The MQTT client ID. It will be autogenerated if not specified.
keepalive | The MQTT keepalive value.



### single(topic, payload, qos, retain, hostname, port, client_id, keepalive)

Connec to hostname and send a single message. Disconnect when message is sent.

Parameter | Description
----------|------------
topic     | The MQTT topic of the message.
payload   | The MQTT message payload. Optional.
qos       | The MQTT _Quality of service_ level for message. Optional.
retain    | Boolean to indicate if message should be _retained_ or not.
hostname  | Hostname of the broker. _localhost_ will be used if not specified.
port      | The TCP port number to use for connection. _1883_ if not specified.
client_id | The MQTT client ID. It will be autogenerated if not specified.
keepalive | The MQTT keepalive value.


## License

MIT/X11

