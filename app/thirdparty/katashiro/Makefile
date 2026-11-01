PLATFORM=$(shell uname -o)
ifeq ($(PLATFORM),Darwin)
	EXT=dylib
else
	EXT=so
endif

ARCH=$(shell uname -m)

debug:
	cargo build --target $(target)
	cp target/${target}/debug/libkatashiro_gd.$(EXT) addons/katashiro/lib/libkatashiro_gd.debug.$(ARCH).$(EXT)

release:
	cargo build --release --target $(target)
	cp target/${target}/release/libkatashiro_gd.$(EXT) addons/katashiro/lib/libkatashiro_gd.release.$(ARCH).$(EXT)

package: debug | release
