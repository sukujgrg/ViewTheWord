.PHONY: build build-for-this clean

clean:
	rm -rf build

build: clean
	./build.sh

build-for-this: clean
	./build.sh --current-arch
