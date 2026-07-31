# The service is C. The library and the daemon compile with clang and need no Swift toolchain,
# and this is the only place either one is built — Package.swift deliberately does not declare
# wabed, so there is exactly one daemon binary and `wabe install` ships the one you ran.
#
# Swift shows up only in things that genuinely need it: the control CLI, the offline replay tool,
# and the SceneKit demo. Running the service needs none of them; `make install` uses the CLI, so
# that one path does want a Swift toolchain.
#
#   make            libwabe + wabed          (C, no Swift)
#   make tools      wabe + wabe-replay       (Swift)
#   make demo       build and run the tavoletta demo
#   make install    launchd agent, per user, no root
#   make uninstall

BUILD    := build
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

.PHONY: all tools demo install uninstall clean

# Stated explicitly because the generated dependency files included at the bottom carry rules of
# their own: whichever target make sees first would otherwise become the default, and `make` would
# quietly rebuild one object file instead of the daemon.
.DEFAULT_GOAL := all

all: $(BUILD)/wabed $(BUILD)/libwabe.a

$(BUILD)/libwabe.a: $(LIB_OBJ)
	@mkdir -p $(dir $@)
	ar rcs $@ $^

$(BUILD)/wabed: $(BUILD)/Sources/wabed/main.o $(BUILD)/libwabe.a
	@mkdir -p $(dir $@)
	$(CC) -o $@ $^ $(LDLIBS)

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

# Swift consumers. Separate on purpose: the service above does not need any of this.
tools:
	swift build -c release

$(DEMO_BIN):
	swift build -c release --package-path $(DEMO_PKG)

demo: $(DEMO_BIN)
	$(DEMO_BIN)

install: tools $(BUILD)/wabed
	.build/release/wabe install --daemon $(BUILD)/wabed

uninstall: tools
	.build/release/wabe uninstall

clean:
	rm -rf $(BUILD)
	swift package clean
	swift package --package-path $(DEMO_PKG) clean

# Last, so no rule inside them can claim the default goal.
-include $(LIB_OBJ:.o=.d) $(BUILD)/Sources/wabed/main.d
