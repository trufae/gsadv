PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SRC = $(filter-out %_test.v,$(wildcard src/*.v))
BIN = gsadv
VFLAGS ?=

all: $(BIN)

$(BIN): $(SRC) VERSION
	v $(VFLAGS) -o $(BIN) src

install: $(BIN)
	mkdir -p $(BINDIR)
	install -m 755 $(BIN) $(BINDIR)/$(BIN)

uninstall:
	rm -f $(BINDIR)/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: all install uninstall clean
