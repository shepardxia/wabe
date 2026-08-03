# The service is C, all of it, and this is the only place it is built — Package.swift deliberately
# does not declare `wabe`, so there is exactly one binary and `wabe install` ships the one you ran.
# Nothing on the install path needs a Swift toolchain.
#
# Swift is only for the two things that genuinely need it, both optional: the offline replay tool
# and the SceneKit demo.
#
#   make            wabe            (C, no Swift)
#   make install    launchd agent, per user, no root
#   make uninstall
#   make demo       the tavoletta demo, against a current daemon
#   make replay     wabe-replay     (Swift)

BUILD    := build
WABE     := $(BUILD)/wabe
DEMO_PKG := examples/tavoletta
DEMO_BIN := $(DEMO_PKG)/.build/release/tavoletta

CC       ?= clang
CXX      ?= clang++
INCLUDES := -ISources/libwabe -ISources/libwabe/include -ISources/libwabe/third_party
# -MMD -MP: emit header dependencies alongside each object. Without them a change to
# internal.h rebuilds only the .c files you happened to touch, and the rest keep a stale
# struct layout — an ABI mismatch inside one binary, which links clean and then reads
# garbage out of every field past the one that moved.
DEPFLAGS := -MMD -MP
CFLAGS   := -O2 -Wall $(DEPFLAGS) $(INCLUDES)
CXXFLAGS := -O2 -std=c++14 $(DEPFLAGS) $(INCLUDES)
LDLIBS   := -framework IOKit -framework CoreFoundation -lc++

LIB_C    := $(wildcard Sources/libwabe/*.c)
LIB_CXX  := $(wildcard Sources/libwabe/third_party/*.cpp)
LIB_OBJ  := $(LIB_C:%.c=$(BUILD)/%.o) $(LIB_CXX:%.cpp=$(BUILD)/%.o)
CLI_C    := $(wildcard Sources/wabe/*.c)
CLI_OBJ  := $(CLI_C:%.c=$(BUILD)/%.o)

.PHONY: all replay demo install uninstall clean

# Stated explicitly because the generated dependency files included at the bottom carry rules of
# their own: whichever target make sees first would otherwise become the default, and `make` would
# quietly rebuild one object file instead of the daemon.
.DEFAULT_GOAL := all

all: $(WABE) $(BUILD)/libwabe.a

$(BUILD)/libwabe.a: $(LIB_OBJ)
	@mkdir -p $(dir $@)
	ar rcs $@ $^

$(WABE): $(CLI_OBJ) $(BUILD)/libwabe.a
	@mkdir -p $(dir $@)
	$(CC) -o $@ $^ $(LDLIBS)

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

install: $(WABE)
	$(WABE) install

uninstall: $(WABE)
	$(WABE) uninstall

# Through install on purpose. The demo is a socket client: it renders whatever daemon is serving,
# which is the installed agent and not the binary a build just produced. Left to itself it will
# happily show a filter from weeks ago and say nothing, so the only honest `make demo` is one that
# replaces the agent first.
#
# The demo build itself is phony and runs every time: SwiftPM already tracks its own sources, and
# a file rule on the binary would shadow that tracking with make's own — which, having no
# prerequisites it can see, would call an edited demo up to date and run the stale one.
demo: install
	swift build -c release --package-path $(DEMO_PKG)
	$(DEMO_BIN)

# Swift, and only here: replaying a capture is a developer's errand, not part of running the service.
replay:
	swift build -c release

clean:
	rm -rf $(BUILD)
	swift package clean
	swift package --package-path $(DEMO_PKG) clean

# Last, so no rule inside them can claim the default goal.
-include $(LIB_OBJ:.o=.d) $(CLI_OBJ:.o=.d)
