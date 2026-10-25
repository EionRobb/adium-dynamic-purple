VERSION ?= 0.2.1
ARCHS ?= x86_64
DEPS ?= deps
SDK ?= $(DEPS)/MacOSX10.6.sdk
FW := $(DEPS)/Frameworks
MACPORTS_PREFIX ?= /opt/local
PKG_CONFIG ?= $(MACPORTS_PREFIX)/bin/pkg-config
CC_x86_64 ?= clang -arch x86_64
LIPO ?= lipo
OTOOL ?= otool
INSTALL_NAME_TOOL ?= install_name_tool
BACKEND_CC ?= clang
BACKEND_CFLAGS ?=
BACKEND_LDFLAGS ?=
PLUGIN := build/DynamicPurple.AdiumLibpurplePlugin
FRONTEND := ADPBackend ADPService ADPAccount ADPAccountView ADPJoinChatView ADPPlugin
CFLAGS := -isysroot $(SDK) -mmacosx-version-min=10.8 -O2 -g -Wall -Wextra \
 -Wno-deprecated-declarations -Wno-unused-parameter -F$(FW) -ISource
LINK := -isysroot $(SDK) -mmacosx-version-min=10.8 -F$(FW) \
 -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/../Frameworks \
 -framework Cocoa -framework Adium -framework AIUtilities

.PHONY: all clean dist test inspect
all: $(PLUGIN)/Contents/Info.plist

define ARCH_RULES
build/$(1)/%.o: Source/%.m $$(wildcard Source/*.h)
	@mkdir -p $$(@D)
	$$(CC_$(1)) $(CFLAGS) -include Cocoa/Cocoa.h -c $$< -o $$@
build/$(1)/DynamicPurple: $$(addprefix build/$(1)/,$$(addsuffix .o,$(FRONTEND))) scripts/normalize-frameworks.sh
	$$(CC_$(1)) $(LINK) -bundle $$(filter %.o,$$^) -o $$@
	OTOOL='$$(OTOOL)' INSTALL_NAME_TOOL='$$(INSTALL_NAME_TOOL)' sh scripts/normalize-frameworks.sh $$@
endef
$(foreach a,$(ARCHS),$(eval $(call ARCH_RULES,$(a))))

# Only this separate executable links to MacPorts.
build/macports-purple-backend: $(wildcard Backend/*.c) $(wildcard Backend/*.h)
	@mkdir -p build
	$(BACKEND_CC) $(BACKEND_CFLAGS) -DADP_VERSION='"$(VERSION)"' -O2 -g -Wall -Wextra -Wno-unused-parameter $(wildcard Backend/*.c) \
	 `$(PKG_CONFIG) --cflags --libs purple json-glib-1.0` $(BACKEND_LDFLAGS) -o $@

$(PLUGIN)/Contents/MacOS/DynamicPurple: $(foreach a,$(ARCHS),build/$(a)/DynamicPurple)
	mkdir -p $(@D)
	$(LIPO) -create $^ -output $@
$(PLUGIN)/Contents/MacOS/macports-purple-backend: build/macports-purple-backend
	mkdir -p $(@D)
	cp $< $@
$(PLUGIN)/Contents/Info.plist: $(PLUGIN)/Contents/MacOS/DynamicPurple $(PLUGIN)/Contents/MacOS/macports-purple-backend Resources/Info.plist Makefile
	sed 's/@VERSION@/$(VERSION)/g' Resources/Info.plist > $@
	printf 'BNDL????' > $(PLUGIN)/Contents/PkgInfo
dist: all
	cd build && zip -qry DynamicPurple-$(VERSION).zip DynamicPurple.AdiumLibpurplePlugin
test: all
	DEPS='$(abspath $(DEPS))' SDK='$(abspath $(SDK))' PKG_CONFIG='$(PKG_CONFIG)' sh tests/system-backend.sh
inspect: all
	printf '{"command":"discover"}\n' | build/macports-purple-backend
clean:
	rm -rf build
