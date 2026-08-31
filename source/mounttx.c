#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>

#ifndef MNT_DETACH
#define MNT_DETACH 2
#endif

#define MAX_ROWS 96
#define MAX_PIDS 256
#define MAX_NS 256
#define MAX_LINE 4096
#define ARRAY_LEN(x) ((int)(sizeof(x) / sizeof((x)[0])))

typedef struct Row {
    char name[128];
    int user;
    char src[PATH_MAX];
    char target[PATH_MAX];
    char lower[PATH_MAX];
    char visible[PATH_MAX];
    int enabled;
    char group[128];
    char profile[128];
    char policy[64];
    int create;
    char migrate[64];
} Row;

typedef struct RowSet {
    Row rows[MAX_ROWS];
    int count;
} RowSet;

typedef struct Options {
    const char *old_rows;
    const char *new_rows;
    const char *runtime;
    const char *moddir;
    const char *data_dir;
    const char *log_path;
    const char *generation_path;
    const char *generation;
    const char *tag;
    int timeout_ms;
} Options;

static Options g_opt;

static void msleep_int(int ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
}

static void timestamp(char *buf, size_t sz) {
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    (void)strftime(buf, sz, "%Y-%m-%d %H:%M:%S", &tmv);
}

static void log_msg(const char *level, const char *fmt, ...) {
    if (!g_opt.log_path || !*g_opt.log_path) return;
    FILE *fp = fopen(g_opt.log_path, "a");
    if (!fp) return;
    char ts[32];
    timestamp(ts, sizeof(ts));
    fprintf(fp, "%s [%s] [mounttx] ", ts, level);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(fp, fmt, ap);
    va_end(ap);
    fputc('\n', fp);
    fclose(fp);
}

static int read_first_line(const char *path, char *buf, size_t sz) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sz - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    char *p = strpbrk(buf, "\r\n");
    if (p) *p = '\0';
    return 0;
}

static bool generation_current(void) {
    if (!g_opt.generation_path || !g_opt.generation || !*g_opt.generation) return true;
    char buf[512];
    if (read_first_line(g_opt.generation_path, buf, sizeof(buf)) != 0) return false;
    return strcmp(buf, g_opt.generation) == 0;
}

static int mkdir_p(const char *path, mode_t mode) {
    if (!path || !*path) return -1;
    char tmp[PATH_MAX];
    if (snprintf(tmp, sizeof(tmp), "%s", path) >= (int)sizeof(tmp)) return -1;
    size_t len = strlen(tmp);
    if (len == 0) return -1;
    if (tmp[len - 1] == '/' && len > 1) tmp[len - 1] = '\0';
    for (char *p = tmp + 1; *p; ++p) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, mode) < 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, mode) < 0 && errno != EEXIST) return -1;
    return 0;
}

static bool path_is_dir(const char *p) {
    struct stat st;
    return p && *p && stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static bool stat_same(const char *a, const char *b) {
    struct stat sa, sb;
    if (stat(a, &sa) != 0 || stat(b, &sb) != 0) return false;
    return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

static int open_ns_fd_for_pid(pid_t pid) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/ns/mnt", pid);
    return open(p, O_RDONLY | O_CLOEXEC);
}

static int setns_pid_restore(pid_t pid, int *orig_fd) {
    *orig_fd = open("/proc/self/ns/mnt", O_RDONLY | O_CLOEXEC);
    if (*orig_fd < 0) return -1;
    int fd = open_ns_fd_for_pid(pid);
    if (fd < 0) {
        close(*orig_fd);
        *orig_fd = -1;
        return -1;
    }
    int rc = setns(fd, CLONE_NEWNS);
    close(fd);
    if (rc < 0) {
        close(*orig_fd);
        *orig_fd = -1;
        return -1;
    }
    return 0;
}

static void restore_ns(int orig_fd) {
    if (orig_fd >= 0) {
        (void)setns(orig_fd, CLONE_NEWNS);
        close(orig_fd);
    }
}

static bool is_pid_alive(pid_t pid) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/ns/mnt", pid);
    return access(p, R_OK) == 0;
}

static bool read_cmdline(pid_t pid, char *buf, size_t sz) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/cmdline", pid);
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    ssize_t n = read(fd, buf, sz - 1);
    close(fd);
    if (n <= 0) return false;
    buf[n] = '\0';
    for (ssize_t i = 0; i < n; ++i) {
        if (buf[i] == '\0') { buf[i] = '\0'; break; }
    }
    return true;
}

static bool cmd_matches(const char *cmd, const char *name) {
    if (!cmd || !name) return false;
    size_t n = strlen(name);
    return strcmp(cmd, name) == 0 || (strncmp(cmd, name, n) == 0 && cmd[n] == ':');
}

static bool get_ns_link(pid_t pid, char *buf, size_t sz) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/ns/mnt", pid);
    ssize_t n = readlink(p, buf, sz - 1);
    if (n <= 0) return false;
    buf[n] = '\0';
    return true;
}

static bool add_unique_pid(pid_t *pids, int *count, pid_t pid, char ns_seen[][128], int *ns_count) {
    if (pid <= 0 || !is_pid_alive(pid)) return false;
    char ns[128];
    if (!get_ns_link(pid, ns, sizeof(ns))) return false;
    for (int i = 0; i < *ns_count; ++i) {
        if (strcmp(ns_seen[i], ns) == 0) return false;
    }
    if (*count >= MAX_PIDS || *ns_count >= MAX_NS) return false;
    pids[(*count)++] = pid;
    snprintf(ns_seen[(*ns_count)++], 128, "%s", ns);
    return true;
}

static void scan_pids_by_cmd(const char *const *names, int names_count, pid_t *pids, int *count, char ns_seen[][128], int *ns_count) {
    DIR *d = opendir("/proc");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        char *end = NULL;
        long v = strtol(de->d_name, &end, 10);
        if (!end || *end != '\0' || v <= 0 || v > INT_MAX) continue;
        char cmd[256];
        if (!read_cmdline((pid_t)v, cmd, sizeof(cmd))) continue;
        for (int i = 0; i < names_count; ++i) {
            if (cmd_matches(cmd, names[i])) {
                (void)add_unique_pid(pids, count, (pid_t)v, ns_seen, ns_count);
                break;
            }
        }
    }
    closedir(d);
}

static int core_pids_base(int user, pid_t *pids, int maxp) {
    (void)maxp;
    int count = 0;
    int ns_count = 0;
    char ns_seen[MAX_NS][128];
    (void)add_unique_pid(pids, &count, 1, ns_seen, &ns_count);
    const char *core_names[] = {
        "system_server", "zygote64", "zygote", "android.process.media",
        "com.android.externalstorage", "sdcard", "vold"
    };
    scan_pids_by_cmd(core_names, ARRAY_LEN(core_names), pids, &count, ns_seen, &ns_count);
    const char *media_names[] = {
        "com.android.providers.media.module",
        "com.google.android.providers.media.module",
        "com.android.providers.media"
    };
    scan_pids_by_cmd(media_names, ARRAY_LEN(media_names), pids, &count, ns_seen, &ns_count);
    (void)user;
    return count;
}

static bool ns_path_exists(pid_t pid, const char *path) {
    int orig = -1;
    bool ok = false;
    if (setns_pid_restore(pid, &orig) == 0) {
        ok = access(path, F_OK) == 0;
        restore_ns(orig);
    }
    return ok;
}

static pid_t media_pid_for_user(int user) {
    char cf[PATH_MAX];
    if (g_opt.runtime) {
        snprintf(cf, sizeof(cf), "%s/media_provider_ns.%d.cache", g_opt.runtime, user);
        FILE *fp = fopen(cf, "r");
        if (fp) {
            char line[256];
            pid_t pid = -1;
            char ns[128] = {0};
            while (fgets(line, sizeof(line), fp)) {
                if (strncmp(line, "PID=", 4) == 0) pid = (pid_t)atoi(line + 4);
                else if (strncmp(line, "NS=", 3) == 0) {
                    size_t nlen = strcspn(line + 3, "\r\n");
                    if (nlen >= sizeof(ns)) nlen = sizeof(ns) - 1;
                    memcpy(ns, line + 3, nlen);
                    ns[nlen] = '\0';
                }
            }
            fclose(fp);
            if (pid > 0 && is_pid_alive(pid)) {
                char now[128];
                if (!*ns || (get_ns_link(pid, now, sizeof(now)) && strcmp(now, ns) == 0)) return pid;
            }
        }
    }
    const char *media_names[] = {
        "com.android.providers.media.module",
        "com.google.android.providers.media.module",
        "com.android.providers.media"
    };
    DIR *d = opendir("/proc");
    if (!d) return -1;
    char user_path[64];
    snprintf(user_path, sizeof(user_path), "/storage/emulated/%d", user);
    struct dirent *de;
    pid_t fallback = -1;
    while ((de = readdir(d)) != NULL) {
        char *end = NULL;
        long v = strtol(de->d_name, &end, 10);
        if (!end || *end != '\0' || v <= 0 || v > INT_MAX) continue;
        char cmd[256];
        if (!read_cmdline((pid_t)v, cmd, sizeof(cmd))) continue;
        bool is_media = false;
        for (int i = 0; i < ARRAY_LEN(media_names); ++i) {
            if (cmd_matches(cmd, media_names[i])) { is_media = true; break; }
        }
        if (!is_media) continue;
        if (fallback < 0) fallback = (pid_t)v;
        if (ns_path_exists((pid_t)v, user_path)) {
            closedir(d);
            return (pid_t)v;
        }
    }
    closedir(d);
    return fallback;
}

static bool mount_entry_at(const char *dst, char *src_out, size_t src_sz, char *fstype_out, size_t fs_sz) {
    FILE *fp = fopen("/proc/self/mounts", "r");
    if (!fp) return false;
    char line[4096];
    bool found = false;
    while (fgets(line, sizeof(line), fp)) {
        char src[PATH_MAX], mnt[PATH_MAX], fs[128];
        if (sscanf(line, "%1023s %1023s %127s", src, mnt, fs) == 3) {
            if (strcmp(mnt, dst) == 0) {
                if (src_out && src_sz) snprintf(src_out, src_sz, "%s", src);
                if (fstype_out && fs_sz) snprintf(fstype_out, fs_sz, "%s", fs);
                found = true;
                break;
            }
        }
    }
    fclose(fp);
    return found;
}

static bool is_bindfs_mounted_here(const char *dst) {
    char src[PATH_MAX] = {0};
    char fs[128] = {0};
    if (!mount_entry_at(dst, src, sizeof(src), fs, sizeof(fs))) return false;
    return strncmp(fs, "fuse", 4) == 0 || strstr(src, "bindfs") != NULL || strcmp(src, "bindfs_shared") == 0;
}

static bool is_any_mount_here(const char *dst) {
    return mount_entry_at(dst, NULL, 0, NULL, 0);
}

static int unmount_pid_if_ours(pid_t pid, const Row *r) {
    int orig = -1;
    int rc = 0;
    if (setns_pid_restore(pid, &orig) != 0) return 0;
    if (strcmp(r->policy, "bindfs_shared") == 0) {
        if (is_bindfs_mounted_here(r->lower)) {
            if (umount2(r->lower, 0) != 0 && umount2(r->lower, MNT_DETACH) != 0) rc = -1;
        }
    } else {
        if (stat_same(r->src, r->lower)) {
            if (umount2(r->lower, 0) != 0 && umount2(r->lower, MNT_DETACH) != 0) rc = -1;
        }
    }
    restore_ns(orig);
    return rc;
}

static int unmount_core(const Row *r) {
    pid_t pids[MAX_PIDS];
    int n = core_pids_base(r->user, pids, MAX_PIDS);
    int fail = 0;
    for (int i = 0; i < n; ++i) {
        if (!generation_current()) return 75;
        if (unmount_pid_if_ours(pids[i], r) != 0) fail++;
    }
    int orig = -1;
    if (setns_pid_restore(1, &orig) == 0) {
        if (strcmp(r->policy, "bindfs_shared") == 0) {
            if (is_bindfs_mounted_here(r->lower)) (void)umount2(r->lower, MNT_DETACH);
        } else if (stat_same(r->src, r->lower)) {
            (void)umount2(r->lower, MNT_DETACH);
        }
        restore_ns(orig);
    }
    return fail ? 1 : 0;
}

static int bind_pid(pid_t pid, const Row *r) {
    int orig = -1;
    int rc = -1;
    if (setns_pid_restore(pid, &orig) != 0) return -1;
    (void)mkdir_p(r->lower, 0770);
    if (stat_same(r->src, r->lower)) rc = 0;
    else if (mount(r->src, r->lower, NULL, MS_BIND, NULL) == 0 && stat_same(r->src, r->lower)) rc = 0;
    restore_ns(orig);
    return rc;
}

static int bind_core(const Row *r) {
    pid_t pids[MAX_PIDS];
    int n = core_pids_base(r->user, pids, MAX_PIDS);
    int ok = 0;
    for (int i = 0; i < n; ++i) {
        if (!generation_current()) return 75;
        if (bind_pid(pids[i], r) == 0) ok++;
    }
    return ok > 0 && stat_same(r->src, r->lower) ? 0 : 1;
}

static int read_uid_from_cache_or_default(int user) {
    if (g_opt.runtime) {
        char cf[PATH_MAX];
        snprintf(cf, sizeof(cf), "%s/media_provider_ns.%d.cache", g_opt.runtime, user);
        FILE *fp = fopen(cf, "r");
        if (fp) {
            char line[256];
            int uid = -1;
            while (fgets(line, sizeof(line), fp)) {
                if (strncmp(line, "UID=", 4) == 0) { uid = atoi(line + 4); break; }
            }
            fclose(fp);
            if (uid > 0) return uid;
        }
    }
    return user * 100000 + 10513;
}

static int wait_pid_timeout(pid_t pid, int timeout_ms, int *status_out) {
    int elapsed = 0;
    int status = 0;
    while (elapsed <= timeout_ms) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            if (status_out) *status_out = status;
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
            return 1;
        }
        if (r < 0 && errno != EINTR) return 127;
        msleep_int(50);
        elapsed += 50;
    }
    kill(pid, SIGTERM);
    msleep_int(100);
    kill(pid, SIGKILL);
    (void)waitpid(pid, &status, 0);
    if (status_out) *status_out = status;
    return 124;
}

static int run_bindfs_helper_in_pid(pid_t pid, const Row *r) {
    int uid = read_uid_from_cache_or_default(r->user);
    char helper[PATH_MAX];
    char bindfs[PATH_MAX];
    char uid_s[32];
    char gid_s[32];
    snprintf(helper, sizeof(helper), "%s/bin/bindfs_mount.sh", g_opt.moddir ? g_opt.moddir : "/data/adb/modules/dcimswitch");
    snprintf(bindfs, sizeof(bindfs), "%s/bin/bindfs", g_opt.moddir ? g_opt.moddir : "/data/adb/modules/dcimswitch");
    snprintf(uid_s, sizeof(uid_s), "%d", uid);
    snprintf(gid_s, sizeof(gid_s), "%d", 1023);

    pid_t child = fork();
    if (child < 0) return 127;
    if (child == 0) {
        int fd = open_ns_fd_for_pid(pid);
        if (fd < 0 || setns(fd, CLONE_NEWNS) != 0) _exit(120);
        if (fd >= 0) close(fd);
        (void)mkdir_p(r->lower, 0770);
        setenv("MODDIR", g_opt.moddir ? g_opt.moddir : "/data/adb/modules/dcimswitch", 1);
        setenv("DATA_DIR", g_opt.data_dir ? g_opt.data_dir : "/data/adb/dcimswitch", 1);
        setenv("BINDFS_PATH", bindfs, 1);
        setenv("PATH", "/data/adb/modules/dcimswitch/bin:/data/adb/dcimswitch/native/bin:/system/bin:/system/xbin:/vendor/bin", 1);
        execl("/system/bin/sh", "sh", helper, uid_s, gid_s, r->src, r->lower, (char *)NULL);
        execl("/bin/sh", "sh", helper, uid_s, gid_s, r->src, r->lower, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    int rc = wait_pid_timeout(child, g_opt.timeout_ms > 0 ? g_opt.timeout_ms : 9000, &st);
    return rc;
}

static int bindfs_mount_pid(pid_t pid, const Row *r) {
    int orig = -1;
    int rc = 1;
    if (setns_pid_restore(pid, &orig) != 0) return 1;
    (void)mkdir_p(r->lower, 0770);
    if (is_bindfs_mounted_here(r->lower)) {
        restore_ns(orig);
        return 0;
    }
    if (is_any_mount_here(r->lower)) {
        (void)umount2(r->lower, MNT_DETACH);
    }
    restore_ns(orig);
    int helper_rc = run_bindfs_helper_in_pid(pid, r);
    if (helper_rc != 0) {
        log_msg("錯誤", "bindfs_shared native helper 失敗｜pid=%d｜rc=%d｜名稱=%s｜%s → %s", pid, helper_rc, r->name, r->src, r->lower);
        return 1;
    }
    if (setns_pid_restore(pid, &orig) == 0) {
        rc = is_bindfs_mounted_here(r->lower) ? 0 : 1;
        restore_ns(orig);
    }
    return rc;
}

static int bindfs_core(const Row *r) {
    int ok = 0;
    pid_t mp = media_pid_for_user(r->user);
    pid_t targets[2];
    int tn = 0;
    targets[tn++] = 1;
    if (mp > 0 && mp != 1) targets[tn++] = mp;
    char seen[2][128];
    int sn = 0;
    for (int i = 0; i < tn; ++i) {
        if (!generation_current()) return 75;
        char ns[128];
        if (!get_ns_link(targets[i], ns, sizeof(ns))) continue;
        bool dup = false;
        for (int j = 0; j < sn; ++j) if (strcmp(seen[j], ns) == 0) dup = true;
        if (dup) continue;
        snprintf(seen[sn++], 128, "%s", ns);
        if (bindfs_mount_pid(targets[i], r) == 0) ok++;
    }
    if (ok <= 0) return 1;
    if (mp > 0) {
        int orig = -1;
        bool mounted = false;
        if (setns_pid_restore(mp, &orig) == 0) {
            mounted = is_bindfs_mounted_here(r->lower);
            restore_ns(orig);
        }
        if (!mounted) return 1;
    }
    return 0;
}

static int mount_core(const Row *r) {
    if (strcmp(r->policy, "bindfs_shared") == 0) {
        log_msg("資訊", "Profile native bindfs_shared 掛載｜User=%d｜名稱=%s｜%s → %s", r->user, r->name, r->src, r->lower);
        return bindfs_core(r);
    }
    log_msg("資訊", "Profile native kernel-bind 掛載｜User=%d｜名稱=%s｜%s → %s", r->user, r->name, r->src, r->lower);
    return bind_core(r);
}

static bool test_visible_once(const Row *r) {
    if (r->visible[0] == '\0') return true;
    char probe[PATH_MAX];
    char rel[PATH_MAX];
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    int plen = snprintf(probe, sizeof(probe), "%s/.yawasau_mounttx_probe.%ld.%ld.%d", r->src, (long)ts.tv_sec, (long)ts.tv_nsec, (int)getpid());
    if (plen < 0 || plen >= (int)sizeof(probe)) return false;
    int fd = open(probe, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return path_is_dir(r->visible);
    close(fd);
    const char *base = strrchr(probe, '/');
    base = base ? base + 1 : probe;
    int rlen = snprintf(rel, sizeof(rel), "%s/%s", r->visible, base);
    bool ok = false;
    if (rlen >= 0 && rlen < (int)sizeof(rel)) ok = access(rel, F_OK) == 0;
    if (!ok) {
        pid_t mp = media_pid_for_user(r->user);
        if (mp > 0) {
            int orig = -1;
            if (setns_pid_restore(mp, &orig) == 0) {
                ok = access(rel, F_OK) == 0;
                restore_ns(orig);
            }
        }
    }
    unlink(probe);
    return ok;
}

static bool visible_probe_retry(const Row *r, const char *phase) {
    int delays[] = {0, 120, 250, 450};
    for (int i = 0; i < ARRAY_LEN(delays); ++i) {
        msleep_int(delays[i]);
        if (test_visible_once(r)) {
            if (i > 0) log_msg("資訊", "native 可見性驗證重試成功｜階段=%s｜名稱=%s｜路徑=%s｜try=%d", phase, r->name, r->visible, i);
            return true;
        }
    }
    return false;
}

static void trim_crlf(char *s) {
    if (!s) return;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = '\0';
}

static bool parse_int_field(const char *s, int *out) {
    if (!s || !*s) return false;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (!end || *end != '\0' || v < 0 || v > INT_MAX) return false;
    *out = (int)v;
    return true;
}

static int parse_row_line(char *line, Row *r) {
    trim_crlf(line);
    if (line[0] == '\0') return 1;
    char *fields[12] = {0};
    int nf = 0;
    char *p = line;
    while (nf < 12) {
        fields[nf++] = p;
        char *bar = strchr(p, '|');
        if (!bar) break;
        *bar = '\0';
        p = bar + 1;
    }
    if (nf < 12) return -1;
    memset(r, 0, sizeof(*r));
    snprintf(r->name, sizeof(r->name), "%s", fields[0]);
    if (!parse_int_field(fields[1], &r->user)) return -1;
    snprintf(r->src, sizeof(r->src), "%s", fields[2]);
    snprintf(r->target, sizeof(r->target), "%s", fields[3]);
    snprintf(r->lower, sizeof(r->lower), "%s", fields[4]);
    snprintf(r->visible, sizeof(r->visible), "%s", fields[5]);
    (void)parse_int_field(fields[6], &r->enabled);
    snprintf(r->group, sizeof(r->group), "%s", fields[7]);
    snprintf(r->profile, sizeof(r->profile), "%s", fields[8]);
    snprintf(r->policy, sizeof(r->policy), "%s", fields[9][0] ? fields[9] : "preserve");
    (void)parse_int_field(fields[10], &r->create);
    snprintf(r->migrate, sizeof(r->migrate), "%s", fields[11]);
    return 0;
}

static int read_rows(const char *path, RowSet *set) {
    memset(set, 0, sizeof(*set));
    FILE *fp = fopen(path, "r");
    if (!fp) return errno == ENOENT ? 0 : -1;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), fp)) {
        if (set->count >= MAX_ROWS) { fclose(fp); return -2; }
        Row r;
        int pr = parse_row_line(line, &r);
        if (pr < 0) { fclose(fp); return -3; }
        if (pr == 0) set->rows[set->count++] = r;
    }
    fclose(fp);
    return 0;
}

static int rollback_rows(const RowSet *new_rows, const RowSet *old_rows) {
    int delays[] = {0, 150, 300, 600};
    log_msg("警告", "Profile native rollback 開始｜tag=%s｜new=%d｜old=%d", g_opt.tag ? g_opt.tag : "-", new_rows->count, old_rows->count);
    for (int t = 0; t < ARRAY_LEN(delays); ++t) {
        msleep_int(delays[t]);
        for (int i = 0; i < new_rows->count; ++i) (void)unmount_core(&new_rows->rows[i]);
        bool ok = true;
        for (int i = 0; i < old_rows->count; ++i) {
            const Row *r = &old_rows->rows[i];
            if (mount_core(r) != 0 || !visible_probe_retry(r, "rollback")) {
                ok = false;
                break;
            }
        }
        if (ok) {
            log_msg("警告", "Profile native rollback 已驗證舊掛載｜tag=%s｜try=%d", g_opt.tag ? g_opt.tag : "-", t);
            return 10;
        }
    }
    log_msg("錯誤", "Profile native rollback 驗證失敗｜tag=%s", g_opt.tag ? g_opt.tag : "-");
    return 11;
}

static int profile_switch(void) {
    RowSet old_rows, new_rows;
    int ro = read_rows(g_opt.old_rows, &old_rows);
    int rn = read_rows(g_opt.new_rows, &new_rows);
    if (ro != 0 || rn != 0) {
        log_msg("錯誤", "Profile native 讀取 rows 失敗｜old_rc=%d｜new_rc=%d", ro, rn);
        return 5;
    }
    log_msg("資訊", "Profile native transaction 開始｜tag=%s｜old=%d｜new=%d｜generation=%s", g_opt.tag ? g_opt.tag : "-", old_rows.count, new_rows.count, g_opt.generation ? g_opt.generation : "-");
    if (!generation_current()) {
        log_msg("警告", "Profile native transaction 取消：generation 過期｜tag=%s", g_opt.tag ? g_opt.tag : "-");
        return 75;
    }
    for (int i = 0; i < old_rows.count; ++i) {
        const Row *r = &old_rows.rows[i];
        log_msg("資訊", "Profile native 卸載舊來源｜名稱=%s｜%s → %s", r->name, r->src, r->target);
        (void)unmount_core(r);
    }
    for (int i = 0; i < new_rows.count; ++i) {
        const Row *r = &new_rows.rows[i];
        if (!generation_current()) return rollback_rows(&new_rows, &old_rows);
        if (mount_core(r) != 0) {
            log_msg("警告", "Profile native 掛載新來源失敗｜名稱=%s｜%s → %s", r->name, r->src, r->target);
            return rollback_rows(&new_rows, &old_rows);
        }
        if (!visible_probe_retry(r, "switch")) {
            log_msg("警告", "Profile native 可見性驗證失敗｜名稱=%s｜路徑=%s", r->name, r->visible);
            return rollback_rows(&new_rows, &old_rows);
        }
        log_msg("資訊", "Profile native 切換成功｜名稱=%s｜%s → %s", r->name, r->src, r->target);
    }
    log_msg("資訊", "Profile native transaction 完成｜tag=%s", g_opt.tag ? g_opt.tag : "-");
    return 0;
}

static void usage(FILE *fp) {
    fprintf(fp, "usage: mounttx profile-switch --old FILE --new FILE --runtime DIR --moddir DIR --log FILE --generation-file FILE --generation VALUE [--tag TAG] [--timeout-ms N]\n");
}

static const char *arg_value(int *i, int argc, char **argv) {
    if (*i + 1 >= argc) return NULL;
    (*i)++;
    return argv[*i];
}

int main(int argc, char **argv) {
    memset(&g_opt, 0, sizeof(g_opt));
    g_opt.timeout_ms = 9000;
    g_opt.data_dir = "/data/adb/dcimswitch";
    if (argc < 2 || strcmp(argv[1], "profile-switch") != 0) {
        usage(stderr);
        return 2;
    }
    for (int i = 2; i < argc; ++i) {
        const char *a = argv[i];
        const char *v = NULL;
        if (strcmp(a, "--old") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.old_rows = v; }
        else if (strcmp(a, "--new") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.new_rows = v; }
        else if (strcmp(a, "--runtime") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.runtime = v; }
        else if (strcmp(a, "--moddir") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.moddir = v; }
        else if (strcmp(a, "--data-dir") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.data_dir = v; }
        else if (strcmp(a, "--log") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.log_path = v; }
        else if (strcmp(a, "--generation-file") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.generation_path = v; }
        else if (strcmp(a, "--generation") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.generation = v; }
        else if (strcmp(a, "--tag") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.tag = v; }
        else if (strcmp(a, "--timeout-ms") == 0) { v = arg_value(&i, argc, argv); if (!v) return 2; g_opt.timeout_ms = atoi(v); }
        else { usage(stderr); return 2; }
    }
    if (!g_opt.old_rows || !g_opt.new_rows || !g_opt.runtime || !g_opt.moddir || !g_opt.log_path || !g_opt.generation_path || !g_opt.generation) {
        usage(stderr);
        return 2;
    }
    return profile_switch();
}
