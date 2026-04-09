PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
BUILD_DIR = .build/release

.PHONY: build build-debug install uninstall clean test

build:
	swift build -c release

build-debug:
	swift build

install: build
	install -d $(INSTALL_DIR)
	install -m 755 $(BUILD_DIR)/vortex $(INSTALL_DIR)/vortex
	@echo "Installed to $(INSTALL_DIR)/vortex"

uninstall:
	rm -f $(INSTALL_DIR)/vortex
	@echo "Removed $(INSTALL_DIR)/vortex"

clean:
	swift package clean
	rm -rf .build

# Verify the install works
test-install:
	@which vortex
	@vortex --version
	@vortex keys list
	@vortex providers list
