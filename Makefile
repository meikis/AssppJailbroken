SHELL := /bin/zsh

DEVICE_HOST ?=
PACKAGE_GLOB := backend-swift/debs/wiki.qaq.unfaird_*_iphoneos-arm64.deb

.PHONY: build package install test clean-package

build:
	$(MAKE) -C backend-swift package FINALPACKAGE=1 ASSPPWEB_DIR=.. DEVICE_HOST="$(DEVICE_HOST)"
	@ls -t $(PACKAGE_GLOB) | head -n 1

package: build

test:
	cd backend-swift && swift test
	cd frontend && npm test

install: build
	@if [[ -z "$(DEVICE_HOST)" ]]; then echo "DEVICE_HOST is required" >&2; exit 1; fi
	host="$(DEVICE_HOST)"; \
	deb=$$(ls -t $(PACKAGE_GLOB) | head -n 1); \
	remote="/var/tmp/$${deb:t}"; \
	scp "$$deb" "$$host:$$remote"; \
	ssh "$$host" "apt install -y '$$remote'"; \
	curl -fsS "http://$${host#*@}:8080/health"

clean-package:
	rm -rf backend-swift/debs backend-swift/.theos backend-swift/.build/ios-release
