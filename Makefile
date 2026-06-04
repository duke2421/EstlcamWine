CC ?= gcc
CFLAGS ?= -Wall -Wextra -O2 -fPIC
LDFLAGS ?= -shared -ldl

.PHONY: all clean

all: wine_tiocm_pty_shim.so

wine_tiocm_pty_shim.so: wine_tiocm_pty_shim.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f wine_tiocm_pty_shim.so
