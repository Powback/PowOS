# PowOS Overlay Build System Makefile
# Builds all systemd-sysext overlays for PowOS

SHELL := /bin/bash
BUILD_SCRIPT := ./build-overlay.sh

# List of all overlays to build
OVERLAYS := \
	steamdeck-jupiter \
	steamdeck-galileo \
	rog-ally \
	legion-go \
	gaming-mode \
	laptop-power \
	desktop-perf

# Output directory
OUTPUT_DIR := ./output

# Phony targets
.PHONY: all clean list help install \
	$(addprefix build-,$(OVERLAYS))

# Default target
all: $(addprefix build-,$(OVERLAYS))
	@echo ""
	@echo "====================================="
	@echo "All overlays built successfully!"
	@echo "====================================="
	@ls -lh $(OUTPUT_DIR)/*.raw

# Build individual overlays
build-steamdeck-jupiter:
	@echo "Building steamdeck-jupiter overlay..."
	@$(BUILD_SCRIPT) steamdeck-jupiter

build-steamdeck-galileo:
	@echo "Building steamdeck-galileo overlay..."
	@$(BUILD_SCRIPT) steamdeck-galileo

build-rog-ally:
	@echo "Building rog-ally overlay..."
	@$(BUILD_SCRIPT) rog-ally

build-legion-go:
	@echo "Building legion-go overlay..."
	@$(BUILD_SCRIPT) legion-go

build-gaming-mode:
	@echo "Building gaming-mode overlay..."
	@$(BUILD_SCRIPT) gaming-mode

build-laptop-power:
	@echo "Building laptop-power overlay..."
	@$(BUILD_SCRIPT) laptop-power || echo "laptop-power overlay not yet implemented, skipping..."

build-desktop-perf:
	@echo "Building desktop-perf overlay..."
	@$(BUILD_SCRIPT) desktop-perf || echo "desktop-perf overlay not yet implemented, skipping..."

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(OUTPUT_DIR)
	@rm -rf */build
	@echo "Clean complete!"

# List available overlays
list:
	@echo "Available overlays:"
	@for overlay in $(OVERLAYS); do \
		if [ -d "$$overlay" ]; then \
			echo "  ✓ $$overlay"; \
		else \
			echo "  ✗ $$overlay (not implemented)"; \
		fi; \
	done

# Install overlays to system
# NOTE: This should be run during container build, not on live system
install: all
	@echo "Installing overlays to /usr/share/powos/overlays..."
	@mkdir -p /usr/share/powos/overlays
	@cp -v $(OUTPUT_DIR)/*.raw /usr/share/powos/overlays/ || true
	@echo "Installing hardware detection script..."
	@mkdir -p /usr/libexec
	@cp -v detect-and-enable.sh /usr/libexec/powos-hardware-detect
	@chmod +x /usr/libexec/powos-hardware-detect
	@echo "Installation complete!"

# Show help
help:
	@echo "PowOS Overlay Build System"
	@echo ""
	@echo "Usage:"
	@echo "  make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all                 Build all overlays (default)"
	@echo "  clean               Remove build artifacts"
	@echo "  list                List available overlays"
	@echo "  install             Install overlays to system (for container builds)"
	@echo "  build-<overlay>     Build a specific overlay"
	@echo ""
	@echo "Available overlays:"
	@for overlay in $(OVERLAYS); do \
		echo "  - $$overlay"; \
	done
	@echo ""
	@echo "Examples:"
	@echo "  make all                     # Build all overlays"
	@echo "  make build-steamdeck-jupiter # Build only Steam Deck Jupiter overlay"
	@echo "  make clean                   # Clean build artifacts"
