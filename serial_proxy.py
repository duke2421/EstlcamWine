#!/usr/bin/env python3
import argparse
import fcntl
import os
import select
import signal
import struct
import termios
import time


BAUD_TO_CONST = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}

for baud in (230400, 250000, 500000, 1000000):
    name = f"B{baud}"
    if hasattr(termios, name):
        BAUD_TO_CONST[baud] = getattr(termios, name)

CONST_TO_BAUD = {value: baud for baud, value in BAUD_TO_CONST.items()}


def raw_attrs(speed):
    attrs = [
        0,
        0,
        termios.CS8 | termios.CREAD | termios.CLOCAL,
        0,
        speed,
        speed,
        [0] * 32,
    ]
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    return attrs


def set_raw(fd, baud):
    speed = BAUD_TO_CONST[baud]
    termios.tcsetattr(fd, termios.TCSANOW, raw_attrs(speed))
    termios.tcflush(fd, termios.TCIOFLUSH)


def get_baud(fd):
    attrs = termios.tcgetattr(fd)
    return CONST_TO_BAUD.get(attrs[4])


def set_modem_lines(fd, mask):
    fcntl.ioctl(fd, termios.TIOCMSET, struct.pack("I", mask))


def log_line(log, message):
    log.write(f"{time.time():.6f} {message}\n")
    log.flush()


def hexdump(data):
    shown = data[:80].hex(" ")
    suffix = "" if len(data) <= 80 else f" ... +{len(data) - 80} bytes"
    return f"{len(data)} bytes: {shown}{suffix}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="/dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--log", default="serial-proxy.log")
    parser.add_argument("--reset-delay", type=float, default=2.5)
    args = parser.parse_args()

    stop = False

    def handle_signal(signum, frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    real = os.open(args.device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    master, slave = os.openpty()
    slave_name = os.ttyname(slave)

    with open(args.log, "w", encoding="utf-8") as log:
        try:
            set_raw(real, args.baud)
            set_raw(master, args.baud)
            # Keep the real controller side stable. Wine can toggle modem lines on
            # the PTY without resetting the physical Arduino.
            set_modem_lines(real, termios.TIOCM_DTR | termios.TIOCM_RTS)
            log_line(log, f"real={args.device} pty={slave_name} initial_baud={args.baud}")
            print(slave_name, flush=True)

            last_baud = args.baud
            next_baud_check = 0.0
            time.sleep(args.reset_delay)

            while not stop:
                now = time.time()
                if now >= next_baud_check:
                    pty_baud = get_baud(master)
                    if pty_baud and pty_baud != last_baud:
                        set_raw(real, pty_baud)
                        last_baud = pty_baud
                        log_line(log, f"baud -> {pty_baud}")
                    next_baud_check = now + 0.1

                readable, _, _ = select.select([real, master], [], [], 0.1)
                for fd in readable:
                    try:
                        data = os.read(fd, 4096)
                    except BlockingIOError:
                        continue
                    if not data:
                        continue
                    if fd == real:
                        log_line(log, f"controller -> wine {hexdump(data)}")
                        try:
                            os.write(master, data)
                        except OSError as exc:
                            log_line(log, f"controller -> wine write failed errno={exc.errno} {exc.strerror}")
                            stop = True
                    else:
                        log_line(log, f"wine -> controller {hexdump(data)}")
                        try:
                            os.write(real, data)
                        except OSError as exc:
                            log_line(log, f"wine -> controller write failed errno={exc.errno} {exc.strerror}")
                            stop = True
        finally:
            os.close(master)
            os.close(slave)
            os.close(real)


if __name__ == "__main__":
    main()
