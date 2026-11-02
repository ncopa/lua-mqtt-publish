LUA ?= lua5.4
LUA_VERSIONS ?= lua5.1 lua5.2 lua5.3 lua5.4 luajit
BUSTED ?= busted
# kill the run if something hangs instead of blocking forever
TEST_TIMEOUT ?= 120

check:
	timeout $(TEST_TIMEOUT) $(BUSTED) --lua=$(LUA) $(BUSTED_ARGS)

check-all:
	set -e; for lua in $(LUA_VERSIONS); do \
		echo "=== $$lua"; \
		$(MAKE) --no-print-directory check LUA=$$lua; \
	done

.PHONY: check check-all
