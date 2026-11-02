// Recovery update-binary that writes one image to the `ramdisk` partition.
//
// Built twice (see build.sh):
//   -DROOT     embeds stock + Magisk images. Writes Magisk only if the partition holds
//              exactly the stock image (or reports "already rooted" if it holds Magisk).
//   (default)  restore: embeds the stock image and writes it whatever is there now.
// After writing it drops the page cache for the device and reads the image back.
//
// Recovery calls: update-binary <api> <pipe-fd> <zip-path>
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define INCBIN(sym, file)                                                      \
    __asm__(".section .rodata\n.balign 16\n.global " #sym "\n" #sym ":\n"   \
            ".incbin \"" file "\"\n.global " #sym "_end\n" #sym "_end:\n.previous\n"); \
    extern const unsigned char sym[], sym##_end[];

INCBIN(stock_img, STOCK_IMG)
#ifdef ROOT
INCBIN(magisk_img, MAGISK_IMG)
#endif

#define PART "mmcblk0p10"
#define PARTNAME "ramdisk"

static FILE *cmd;

static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fprintf(cmd, "ui_print %s\nui_print\n", line);
    fflush(cmd);
}

// Refuse to touch anything unless mmcblk0p10 really is the ramdisk partition.
static int is_ramdisk_partition(void) {
    char buf[512];
    int fd = open("/sys/class/block/" PART "/uevent", O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    return strstr(buf, "PARTNAME=" PARTNAME "\n") != NULL;
}

static int read_all(int fd, unsigned char *buf, size_t len) {
    for (size_t got = 0; got < len;) {
        ssize_t n = pread(fd, buf + got, len - got, got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        got += n;
    }
    return 0;
}

static int write_all(int fd, const unsigned char *buf, size_t len) {
    for (size_t put = 0; put < len;) {
        ssize_t n = pwrite(fd, buf + put, len - put, put);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        put += n;
    }
    return fsync(fd);
}

// Read back through a dropped page cache so we compare what is on the eMMC.
static int matches(int fd, const unsigned char *img, size_t len, unsigned char *scratch) {
    ioctl(fd, BLKFLSBUF, 0);
    return read_all(fd, scratch, len) == 0 && memcmp(scratch, img, len) == 0;
}

static int flash(int fd, const unsigned char *img, size_t len, unsigned char *scratch, const char *what) {
    say("Writing %s ramdisk (%zu bytes)", what, len);
    if (write_all(fd, img, len)) { say("Write failed: %s", strerror(errno)); return -1; }
    if (!matches(fd, img, len, scratch)) { say("Read-back MISMATCH after writing %s", what); return -1; }
    say("Read-back ok");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3 || !(cmd = fdopen(atoi(argv[2]), "w"))) return 1;
    size_t stock_len = stock_img_end - stock_img;
#ifdef ROOT
    size_t magisk_len = magisk_img_end - magisk_img;
    say("M11 root: Magisk ramdisk");
#else
    say("M11 restore: stock ramdisk");
#endif
    if (!is_ramdisk_partition()) { say(PART " is not the ramdisk partition; nothing written"); return 1; }
    int fd = open("/dev/block/" PART, O_RDWR);
    if (fd < 0) { say("open /dev/block/" PART ": %s", strerror(errno)); return 1; }
    unsigned char *scratch = malloc(10 << 20);

#ifdef ROOT
    size_t big = stock_len > magisk_len ? stock_len : magisk_len;
    if (big > (10 << 20) || !scratch) { say("image too big"); return 1; }
    if (matches(fd, magisk_img, magisk_len, scratch)) { say("Already has this Magisk ramdisk; nothing written"); return 0; }
    if (!matches(fd, stock_img, stock_len, scratch)) {
        say("Ramdisk is not the stock image this package was built from; nothing written");
        return 1;
    }
    say("Stock ramdisk confirmed");
    if (flash(fd, magisk_img, magisk_len, scratch, "Magisk") == 0) {
        say("Done. Android will boot with Magisk.");
        return 0;
    }
    say("Putting the stock ramdisk back");
    if (flash(fd, stock_img, stock_len, scratch, "stock") == 0) return 1;
    say("STOCK RESTORE FAILED: do not reboot; run the restore package");
    return 1;
#else
    if (stock_len > (10 << 20) || !scratch) { say("image too big"); return 1; }
    if (matches(fd, stock_img, stock_len, scratch)) { say("Already stock; nothing written"); return 0; }
    if (flash(fd, stock_img, stock_len, scratch, "stock")) return 1;
    say("Done. Android will boot stock (no Magisk).");
    return 0;
#endif
}
