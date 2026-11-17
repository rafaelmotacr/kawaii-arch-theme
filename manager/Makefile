# kawaii-arch-manager - build
#
#   make                       compila build/kawaii-arch-manager
#   make install DESTDIR=...   instala binario em $(BINDIR)
#   make clean
#
# Dependencias: compilador C11, libarchive e zlib (headers + bibliotecas).

VERSION   := 1.5.0
PREFIX    ?= /usr
BINDIR    ?= $(PREFIX)/bin
BUILD     ?= build

CC        ?= cc
CFLAGS    ?= -O2 -g
CFLAGS    += -std=c11 -D_GNU_SOURCE -Wall -Wextra -Wformat=2 -Wshadow -Wno-format-truncation -Werror=implicit-function-declaration \
             -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE
CPPFLAGS  += -DKAM_VERSION=\"$(VERSION)\"
LDFLAGS   += -pie -Wl,-z,relro,-z,now
LDLIBS    += -larchive -lz -lm

SRCS := $(wildcard src/*.c)
OBJS := $(patsubst src/%.c,$(BUILD)/%.o,$(SRCS))
BIN  := $(BUILD)/kawaii-arch-manager

all: $(BIN)

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: src/%.c src/kam.h Makefile | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/kawaii-arch-manager

clean:
	rm -rf $(BUILD)

version:
	@echo $(VERSION)

.PHONY: all install clean version
