// Recovery update-binary that only READS: dumps every eMMC partition except userdata
// and cache, plus boot0/boot1 and the GPT areas, to /data/media/0/m11-backup*/.
// Nothing on mmcblk0 is opened for writing.
//
// Recovery calls: update-binary <api> <pipe-fd> <zip-path>
// Test on a host or as adb shell: update-binary --dry-run  (lists, reads nothing)
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define MEDIA_RW 1023
#define CHUNK (4 << 20)
#define GPT_AREA (1 << 20)

static FILE *cmd;  // recovery's command pipe, or stdout in dry-run
static int dry_run;

static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (dry_run) {
        printf("%s\n", line);
    } else {
        fprintf(cmd, "ui_print %s\nui_print\n", line);
        fflush(cmd);
    }
}

static void progress(double frac) {
    if (!dry_run) {
        fprintf(cmd, "set_progress %.3f\n", frac);
        fflush(cmd);
    }
}

struct part {
    char name[64];     // PARTNAME, or the device name for boot0/boot1/whole disk
    char dev[32];      // mmcblk0pN
    unsigned maj, min;
    unsigned long long bytes;
    unsigned long long offset;  // only for the whole-disk GPT slices
};

static struct part parts[64];
static int nparts;
static char userdata_dev[32];

static int read_sys(const char *dev, const char *file, char *buf, size_t len) {
    char path[128];
    snprintf(path, sizeof path, "/sys/class/block/%s/%s", dev, file);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = 0;
    return 0;
}

static int add(const char *dev) {
    char ue[512], sz[32];
    struct part p = {0};
    if (read_sys(dev, "uevent", ue, sizeof ue) || read_sys(dev, "size", sz, sizeof sz)) return -1;
    snprintf(p.dev, sizeof p.dev, "%s", dev);
    snprintf(p.name, sizeof p.name, "%s", dev);
    for (char *l = strtok(ue, "\n"); l; l = strtok(NULL, "\n")) {
        if (!strncmp(l, "MAJOR=", 6)) p.maj = atoi(l + 6);
        else if (!strncmp(l, "MINOR=", 6)) p.min = atoi(l + 6);
        else if (!strncmp(l, "PARTNAME=", 9)) snprintf(p.name, sizeof p.name, "%s", l + 9);
    }
    p.bytes = strtoull(sz, NULL, 10) * 512;
    if (!strcmp(p.name, "userdata")) snprintf(userdata_dev, sizeof userdata_dev, "%s", dev);
    if (!strcmp(p.name, "userdata") || !strcmp(p.name, "cache")) return 0;
    if (nparts < 62) parts[nparts++] = p;
    return 0;
}

static int by_dev(const void *a, const void *b) {
    return strverscmp(((const struct part *)a)->dev, ((const struct part *)b)->dev);
}

static int scan(void) {
    DIR *d = opendir("/sys/class/block");
    if (!d) return -1;
    struct dirent *e;
    while ((e = readdir(d))) {
        const char *n = e->d_name;
        if (!strncmp(n, "mmcblk0p", 8) || !strcmp(n, "mmcblk0boot0") || !strcmp(n, "mmcblk0boot1"))
            add(n);
    }
    closedir(d);
    qsort(parts, nparts, sizeof parts[0], by_dev);

    // Primary and backup GPT: first and last 1 MiB of the whole disk.
    struct part disk = {0};
    char sz[32];
    if (read_sys("mmcblk0", "size", sz, sizeof sz) == 0) {
        unsigned long long total = strtoull(sz, NULL, 10) * 512;
        char ue[256];
        read_sys("mmcblk0", "uevent", ue, sizeof ue);
        char *m = strstr(ue, "MAJOR="), *n = strstr(ue, "MINOR=");
        disk.maj = m ? atoi(m + 6) : 179;
        disk.min = n ? atoi(n + 6) : 0;
        strcpy(disk.dev, "mmcblk0");
        disk.bytes = GPT_AREA;
        strcpy(disk.name, "mmcblk0-head");
        parts[nparts++] = disk;
        strcpy(disk.name, "mmcblk0-tail");
        disk.offset = total - GPT_AREA;
        parts[nparts++] = disk;
    }
    return 0;
}

// /dev/block nodes may not exist yet in recovery; fall back to our own node in /tmp.
static int open_dev(const struct part *p) {
    char path[64];
    snprintf(path, sizeof path, "/dev/block/%s", p->dev);
    int fd = open(path, O_RDONLY);
    if (fd >= 0 || errno != ENOENT) return fd;
    snprintf(path, sizeof path, "/tmp/m11bk-%s", p->dev);
    unlink(path);
    if (mknod(path, S_IFBLK | 0400, makedev(p->maj, p->min))) return -1;
    return open(path, O_RDONLY);
}

// Files must belong to media_rw or Android's sdcard daemon can't serve them over MTP/adb.
static void own(const char *path, mode_t mode) {
    if (chown(path, MEDIA_RW, MEDIA_RW) || chmod(path, mode))
        say("  warning: chown/chmod %s: %s", path, strerror(errno));
}

static int mounted(const char *dir) {
    FILE *f = fopen("/proc/mounts", "r");
    char line[512], at[256];
    int found = 0;
    while (f && fgets(line, sizeof line, f))
        if (sscanf(line, "%*s %255s", at) == 1 && !strcmp(at, dir)) found = 1;
    if (f) fclose(f);
    return found;
}

static int dump(const struct part *p, const char *outdir, char *buf,
                unsigned long long *done, unsigned long long total) {
    char out[256];
    snprintf(out, sizeof out, "%s/%s.img", outdir, p->name);
    int in = open_dev(p);
    if (in < 0) { say("  %s: open %s: %s", p->name, p->dev, strerror(errno)); return -1; }
    int o = open(out, O_WRONLY | O_CREAT | O_EXCL, 0664);
    if (o < 0) { say("  %s: create: %s", p->name, strerror(errno)); close(in); return -1; }

    unsigned long long left = p->bytes, pos = p->offset;
    int rc = 0;
    while (left) {
        size_t want = left < CHUNK ? left : CHUNK;
        ssize_t n = pread(in, buf, want, pos);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { say("  %s: read at %llu: %s", p->name, pos, n ? strerror(errno) : "EOF"); rc = -1; break; }
        for (ssize_t w = 0; w < n;) {
            ssize_t k = write(o, buf + w, n - w);
            if (k < 0 && errno == EINTR) continue;
            if (k < 0) { say("  %s: write: %s", p->name, strerror(errno)); rc = -1; goto out; }
            w += k;
        }
        pos += n;
        left -= n;
        *done += n;
        progress((double)*done / total);
    }
out:
    if (fsync(o)) rc = -1;
    close(o);
    close(in);
    if (rc) unlink(out);
    else own(out, 0664);
    return rc;
}

int main(int argc, char **argv) {
    dry_run = argc > 1 && !strcmp(argv[1], "--dry-run");
    if (!dry_run) {
        if (argc < 3 || !(cmd = fdopen(atoi(argv[2]), "w"))) return 1;
    }
    say("M11 partition backup (read-only)");

    if (scan() || nparts == 0) { say("No partitions found in /sys/class/block"); return 1; }
    unsigned long long total = 0;
    for (int i = 0; i < nparts; i++) {
        total += parts[i].bytes;
        if (dry_run) say("  %-14s %-14s %llu", parts[i].name, parts[i].dev, parts[i].bytes);
    }
    say("%d images, %llu MiB", nparts, total >> 20);
    if (dry_run) return 0;

    int we_mounted = 0;
    if (!mounted("/data")) {
        char dev[64];
        snprintf(dev, sizeof dev, "/dev/block/%s", userdata_dev);
        mkdir("/data", 0771);
        if (!userdata_dev[0] || mount(dev, "/data", "ext4", MS_NOATIME | MS_NODEV | MS_NOSUID, "")) {
            say("Cannot mount /data (%s): %s", dev, strerror(errno));
            return 1;
        }
        we_mounted = 1;
    }

    struct statvfs vfs;
    if (statvfs("/data", &vfs) == 0 && (unsigned long long)vfs.f_bavail * vfs.f_bsize < total + (64ULL << 20)) {
        say("Not enough free space on /data");
        if (we_mounted) umount("/data");
        return 1;
    }

    char outdir[128];
    snprintf(outdir, sizeof outdir, "/data/media/0/m11-backup");
    for (int i = 2; mkdir(outdir, 0775) && errno == EEXIST; i++)
        snprintf(outdir, sizeof outdir, "/data/media/0/m11-backup-%d", i);
    own(outdir, 0775);
    say("Writing to %s", outdir + strlen("/data/media/0/"));

    char *buf = malloc(CHUNK);
    char man[160];
    snprintf(man, sizeof man, "%s/manifest.txt", outdir);
    FILE *mf = fopen(man, "w");
    unsigned long long done = 0;
    int failed = 0;
    for (int i = 0; i < nparts; i++) {
        say("%s (%llu MiB)", parts[i].name, parts[i].bytes >> 20);
        int rc = dump(&parts[i], outdir, buf, &done, total);
        if (rc) failed++;
        if (mf) fprintf(mf, "%s %s %llu %llu %s\n", parts[i].name, parts[i].dev,
                        parts[i].offset, parts[i].bytes, rc ? "FAILED" : "ok");
    }
    if (mf) { fflush(mf); fsync(fileno(mf)); fclose(mf); own(man, 0664); }
    sync();
    if (we_mounted) umount("/data");

    say(failed ? "Done with %d FAILED image(s), see manifest.txt" : "Done, all %d images ok",
        failed ? failed : nparts);
    return failed ? 1 : 0;
}
