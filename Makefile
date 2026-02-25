.PHONY: build build-for-this clean release-notarize release-github

NOTARY_PROFILE ?=
GH_REPO ?= sukujgrg/ViewTheWord
TAG ?=
NOTES_FILE ?=
BUILD_NUMBER ?=
SKIP_VERSION_FILE_CHECK ?=

clean:
	rm -rf build

build: clean
	./scripts/build.sh

build-for-this: clean
	./scripts/build.sh --current-arch

release-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then echo "Set NOTARY_PROFILE, e.g. make release-notarize NOTARY_PROFILE=ViewTheWordNotary"; exit 1; fi
	./scripts/release-notarize-distribute.sh --notary-profile "$(NOTARY_PROFILE)" $(if $(TAG),--tag "$(TAG)") $(if $(BUILD_NUMBER),--build-number "$(BUILD_NUMBER)") $(if $(SKIP_VERSION_FILE_CHECK),--skip-version-file-check)

release-github:
	@if [ -z "$(NOTARY_PROFILE)" ]; then echo "Set NOTARY_PROFILE, e.g. make release-github NOTARY_PROFILE=ViewTheWordNotary GH_REPO=owner/repo"; exit 1; fi
	./scripts/release-notarize-distribute.sh --notary-profile "$(NOTARY_PROFILE)" --github --repo "$(GH_REPO)" $(if $(TAG),--tag "$(TAG)") $(if $(BUILD_NUMBER),--build-number "$(BUILD_NUMBER)") $(if $(NOTES_FILE),--notes "$(NOTES_FILE)") $(if $(SKIP_VERSION_FILE_CHECK),--skip-version-file-check)
