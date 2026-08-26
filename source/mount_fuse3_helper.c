/*
 * YAWAsau native mount.fuse3 helper
 * v1.4.62-native-fuse-mount-helper-ro-relatime-flags
 *
 * This helper is executed by libfuse/bindfs inside the target mount
 * namespace. libfuse may pass an already-open /dev/fuse file descriptor as
 * argv[1] (for example "4") plus helper-layer options such as fsname= and
 * subtype=. Android toybox mount does not handle that form reliably from
 * shell. This native helper converts the libfuse helper invocation into a
 * direct mount(2) call and filters options that must not be forwarded to the
 * kernel FUSE mount data.
 */
#define _GNU_SOURCE 1
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef MS_NOSUID
#define MS_NOSUID 2
#endif
#ifndef MS_NODEV
#define MS_NODEV 4
#endif
#ifndef MS_RDONLY
#define MS_RDONLY 1
#endif
#ifndef MS_RELATIME
#define MS_RELATIME (1UL << 21)
#endif

static int is_numeric(const char *s) {
    if (!s || !*s) return 0;
    for (const char *p = s; *p; ++p) {
        if (*p < '0' || *p > '9') return 0;
    }
    return 1;
}

static int starts_with(const char *s, const char *prefix) {
    size_t n = strlen(prefix);
    return strncmp(s, prefix, n) == 0;
}


static int has_prefix_token(const char *buf, const char *prefix) {
    size_t plen = strlen(prefix);
    const char *p = buf;
    while (*p) {
        while (*p == ',') ++p;
        const char *q = strchr(p, ',');
        size_t len = q ? (size_t)(q - p) : strlen(p);
        if (len >= plen && strncmp(p, prefix, plen) == 0) return 1;
        if (!q) break;
        p = q + 1;
    }
    return 0;
}

static int has_token(const char *buf, const char *tok) {
    size_t toklen = strlen(tok);
    const char *p = buf;
    while (*p) {
        while (*p == ',') ++p;
        const char *q = strchr(p, ',');
        size_t len = q ? (size_t)(q - p) : strlen(p);
        if (len == toklen && strncmp(p, tok, toklen) == 0) return 1;
        if (!q) break;
        p = q + 1;
    }
    return 0;
}

static int append_token(char *buf, size_t cap, const char *tok, int unique) {
    if (!tok || !*tok) return 0;
    if (unique && has_token(buf, tok)) return 0;
    size_t cur = strlen(buf);
    size_t need = strlen(tok) + (cur ? 1 : 0) + 1;
    if (cur + need > cap) {
        fprintf(stderr, "mount.fuse3: option data too long while adding %s\n", tok);
        return -1;
    }
    if (cur) strcat(buf, ",");
    strcat(buf, tok);
    return 0;
}

static int wanted_kernel_opt(const char *tok) {
    if (!tok || !*tok) return 0;
    /* Keep ro/rw/relatime in the parsed option buffer for diagnostics, but
     * also convert them into mount(2) flags before calling the kernel.  Older
     * helpers silently dropped ro and therefore changed a read-only request
     * into a writable FUSE mount. */
    if (strcmp(tok, "rw") == 0) return 1;
    if (strcmp(tok, "ro") == 0) return 1;
    if (strcmp(tok, "relatime") == 0) return 1;
    if (strcmp(tok, "nosuid") == 0) return 0;
    if (strcmp(tok, "nodev") == 0) return 0;
    if (strcmp(tok, "allow_other") == 0) return 1;
    if (strcmp(tok, "default_permissions") == 0) return 1;
    if (starts_with(tok, "fd=")) return 1;
    if (starts_with(tok, "rootmode=")) return 1;
    if (starts_with(tok, "user_id=")) return 1;
    if (starts_with(tok, "group_id=")) return 1;
    if (starts_with(tok, "max_read=")) return 1;
    if (starts_with(tok, "blksize=")) return 1;
    if (starts_with(tok, "max_write=")) return 1;

    /* libfuse/helper-level or SELinux userspace options. These caused EINVAL
     * when blindly forwarded through toybox mount in v1.4.47/48. */
    if (starts_with(tok, "fsname=")) return 0;
    if (starts_with(tok, "subtype=")) return 0;
    if (starts_with(tok, "context=")) return 0;
    if (starts_with(tok, "fscontext=")) return 0;
    if (starts_with(tok, "defcontext=")) return 0;
    if (starts_with(tok, "rootcontext=")) return 0;
    return 0;
}

static int add_csv_options(char *data, size_t cap, const char *csv) {
    if (!csv) return 0;
    const char *p = csv;
    while (*p) {
        while (*p == ',' || *p == ' ' || *p == '\t') ++p;
        const char *q = strchr(p, ',');
        size_t len = q ? (size_t)(q - p) : strlen(p);
        while (len && (p[len - 1] == ' ' || p[len - 1] == '\t')) --len;
        if (len) {
            char tok[256];
            if (len >= sizeof(tok)) len = sizeof(tok) - 1;
            memcpy(tok, p, len);
            tok[len] = '\0';
            if (wanted_kernel_opt(tok)) {
                if (append_token(data, cap, tok, 1) != 0) return -1;
            }
        }
        if (!q) break;
        p = q + 1;
    }
    return 0;
}

static void usage(const char *argv0) {
    fprintf(stderr, "usage: %s <fd-or-dev> <mountpoint> [-o options]\n", argv0);
}

static unsigned long mount_flags_from_opts(const char *opts) {
    unsigned long flags = MS_NOSUID | MS_NODEV;
    /* rw is the default; if both appear, ro remains the safer semantic. */
    if (has_token(opts, "ro")) flags |= MS_RDONLY;
    if (has_token(opts, "relatime")) flags |= MS_RELATIME;
    return flags;
}

static int try_mount_variants(const char *target, const char *data_base, int have_rootmode) {
    const char *sources[] = { "bindfs_shared", "/dev/fuse", "fuse" };
    const char *rootmodes[] = { "40000", "040000", "40755" };
    unsigned long flags = mount_flags_from_opts(data_base);
    int last_errno = 0;

    for (size_t r = 0; r < (have_rootmode ? 1u : (sizeof(rootmodes)/sizeof(rootmodes[0]))); ++r) {
        char data[2048];
        snprintf(data, sizeof(data), "%s", data_base);
        if (!have_rootmode) {
            char opt[64];
            snprintf(opt, sizeof(opt), "rootmode=%s", rootmodes[r]);
            if (append_token(data, sizeof(data), opt, 1) != 0) return -1;
        }
        for (size_t s = 0; s < sizeof(sources)/sizeof(sources[0]); ++s) {
            if (mount(sources[s], target, "fuse", flags, data) == 0) {
                return 0;
            }
            last_errno = errno;
            fprintf(stderr, "mount.fuse3: mount source=%s target=%s data=%s failed errno=%d (%s)\n",
                    sources[s], target, data, errno, strerror(errno));
        }
    }
    errno = last_errno ? last_errno : EINVAL;
    return -1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 64;
    }

    /*
     * libfuse does not guarantee the Android helper argv order.  v1.4.53/54
     * assumed argv[1] was the numeric fd and argv[2] was the mountpoint, but
     * the device log showed the real invocation can start with "-o".  In that
     * form the fd is carried inside the comma-separated -o string as fd=N.
     * Parse the whole argv first, then derive mountpoint/fd from positionals
     * and options.  This keeps compatibility with both forms:
     *   mount.fuse3 4 /mnt/point -o allow_other,...
     *   mount.fuse3 -o fd=4,allow_other,... bindfs_shared /mnt/point
     */
    char opts[2048] = {0};
    const char *pos[16];
    int npos = 0;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            if (add_csv_options(opts, sizeof(opts), argv[++i]) != 0) return 66;
            continue;
        }
        if (starts_with(argv[i], "-o") && argv[i][2] != '\0') {
            if (add_csv_options(opts, sizeof(opts), argv[i] + 2) != 0) return 66;
            continue;
        }
        if (argv[i][0] == '-') {
            /* Other helper flags are not useful for the kernel mount data. */
            continue;
        }
        if (npos < (int)(sizeof(pos) / sizeof(pos[0]))) {
            pos[npos++] = argv[i];
        }
    }

    const char *dev_or_fd = NULL;
    const char *target = NULL;
    if (npos >= 2) {
        dev_or_fd = pos[npos - 2];
        target = pos[npos - 1];
    } else if (npos == 1) {
        target = pos[0];
    }

    if (!target || !*target) {
        fprintf(stderr, "mount.fuse3: empty mountpoint; argc=%d npos=%d\n", argc, npos);
        return 65;
    }

    int have_fd = has_prefix_token(opts, "fd=");
    if (!have_fd && dev_or_fd && is_numeric(dev_or_fd)) {
        char fdopt[64];
        snprintf(fdopt, sizeof(fdopt), "fd=%s", dev_or_fd);
        if (append_token(opts, sizeof(opts), fdopt, 1) != 0) return 66;
        have_fd = 1;
    }
    if (!have_fd) {
        fprintf(stderr, "mount.fuse3: no numeric fd supplied by libfuse; dev_or_fd=%s argc=%d npos=%d opts=%s\n",
                dev_or_fd ? dev_or_fd : "<null>", argc, npos, opts[0] ? opts : "<empty>");
        return 67;
    }

    if (!has_prefix_token(opts, "user_id=")) {
        char uopt[64];
        snprintf(uopt, sizeof(uopt), "user_id=%u", (unsigned)getuid());
        if (append_token(opts, sizeof(opts), uopt, 1) != 0) return 66;
    }
    if (!has_prefix_token(opts, "group_id=")) {
        char gopt[64];
        snprintf(gopt, sizeof(gopt), "group_id=%u", (unsigned)getgid());
        if (append_token(opts, sizeof(opts), gopt, 1) != 0) return 66;
    }

    int have_rootmode = has_prefix_token(opts, "rootmode=");
    if (try_mount_variants(target, opts, have_rootmode) == 0) {
        return 0;
    }
    fprintf(stderr, "mount.fuse3: all native mount(2) attempts failed target=%s final_errno=%d (%s)\n",
            target, errno, strerror(errno));
    return 68;
}
