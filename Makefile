.DEFAULT_GOAL := help
.PHONY: help build clean release release-check release-notarize release-publish

NOTARY_PROFILE ?= ViewTheWordNotary
NOTES_FILE ?=
# Optional notes must be outside the checkout, e.g. /tmp/viewtheword-notes.md.

help:
	@printf '%s\n' \
	  'make build             Build an Apple Silicon app into ~/Applications' \
	  'make release           Validate, sign, notarize, tag, and publish from this Mac' \
	  'make release-check     Check source, destination, and CI only' \
	  'make release-notarize  Produce signed local artifacts without publishing' \
	  'make release-publish   Publish saved artifacts without building or notarizing' \
	  'make clean             Remove build caches; preserve saved releases'

clean:
	python3 scripts/release.py --clean

build:
	./scripts/build.sh

ifneq ($(filter release release-check release-notarize release-publish,$(MAKECMDGOALS)),)
ifneq ($(strip $(VERSION)$(TAG)$(BUILD_NUMBER)$(SKIP_VERSION_FILE_CHECK)$(GH_REPO)),)
$(error Release settings are derived automatically. Edit VERSION, commit and merge or push to master, then run make release without VERSION, TAG, BUILD_NUMBER, SKIP_VERSION_FILE_CHECK or GH_REPO overrides)
endif
endif

release:
	python3 scripts/release.py --notary-profile "$(NOTARY_PROFILE)" $(if $(NOTES_FILE),--notes "$(NOTES_FILE)")

release-check:
	python3 scripts/release.py --check

release-notarize:
	python3 scripts/release.py --notary-profile "$(NOTARY_PROFILE)" --no-publish

release-publish:
	python3 scripts/release.py --publish-only $(if $(NOTES_FILE),--notes "$(NOTES_FILE)")
