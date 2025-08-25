.PHONY: bootstrap acl upgrade fmt

ROOT_DIR := $(shell pwd)

bootstrap:
	bin/bootstrap

# Usage: make acl CONFIG=path/to/config.json [ARGS="--dry-run"]
acl:
	@if [ -z "$(CONFIG)" ]; then echo "CONFIG is required. Example: make acl CONFIG=modules/acl/examples/example_1.json"; exit 1; fi
	bin/acl-apply -f "$(CONFIG)" $(ARGS)

upgrade:
	scripts/upgrade.sh

fmt:
	@echo "Formatting shell scripts (no-op placeholder)"

