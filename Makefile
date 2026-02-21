.PHONY: build build-for-this

build:
	./build.sh

build-for-this:
	./build.sh --current-arch
