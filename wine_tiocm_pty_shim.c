#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static int (*real_ioctl)(int fd, unsigned long request, ...) = NULL;

static int is_pts_fd(int fd)
{
    char link_path[64];
    char target[128];
    ssize_t len;

    snprintf(link_path, sizeof(link_path), "/proc/self/fd/%d", fd);
    len = readlink(link_path, target, sizeof(target) - 1);
    if (len < 0) {
        return 0;
    }

    target[len] = '\0';
    return strncmp(target, "/dev/pts/", 9) == 0;
}

static int *fd_state(int fd)
{
    static int states[4096];

    if (fd < 0 || fd >= (int)(sizeof(states) / sizeof(states[0]))) {
        return NULL;
    }

    if (states[fd] == 0) {
        states[fd] = TIOCM_DTR | TIOCM_RTS;
    }

    return &states[fd];
}

int ioctl(int fd, unsigned long request, ...)
{
    va_list args;
    void *arg;
    int rc;

    if (!real_ioctl) {
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    }

    va_start(args, request);
    arg = va_arg(args, void *);
    va_end(args);

    rc = real_ioctl(fd, request, arg);
    if (rc == 0 || errno != ENOTTY || !is_pts_fd(fd)) {
        return rc;
    }

    int *state = fd_state(fd);
    if (!state) {
        return rc;
    }

    switch (request) {
    case TIOCMGET:
        if (!arg) {
            errno = EFAULT;
            return -1;
        }
        *(int *)arg = *state;
        return 0;
    case TIOCMSET:
        if (!arg) {
            errno = EFAULT;
            return -1;
        }
        *state = *(int *)arg;
        return 0;
    case TIOCMBIS:
        if (!arg) {
            errno = EFAULT;
            return -1;
        }
        *state |= *(int *)arg;
        return 0;
    case TIOCMBIC:
        if (!arg) {
            errno = EFAULT;
            return -1;
        }
        *state &= ~(*(int *)arg);
        return 0;
    default:
        return rc;
    }
}
