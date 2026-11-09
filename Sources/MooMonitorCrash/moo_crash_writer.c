#include "include/moo_crash_writer.h"

#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/*
 * 信号处理器运行在被中断的线程上，只能调用异步信号安全函数。
 * 这里只做三件事：填静态结构体 → 一次 write(2) → 恢复默认处理并重新抛出。
 * 不 malloc、不加锁、不碰 Swift 运行时——在被中断的 malloc 上再 malloc 会死锁，
 * 结果是「加了监控之后崩溃报告反而没了」。
 */

static int g_fd = -1;
static moo_crash_frame g_frame;
static uintptr_t g_image_bases[MOO_CRASH_MAX_IMAGES];
static uint32_t g_image_count = 0;

int moo_crash_install(const char *path) {
    if (path == NULL) {
        return -1;
    }
    g_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (g_fd < 0) {
        return -1;
    }

    // image 表只在启动时取一次：_dyld_image_count / _dyld_get_image_header 内部有锁，
    // 信号恰好落在持锁线程上会死锁，所以处理器里只读这份缓存。
    uint32_t total = _dyld_image_count();
    g_image_count = total < MOO_CRASH_MAX_IMAGES ? total : MOO_CRASH_MAX_IMAGES;
    for (uint32_t i = 0; i < g_image_count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        g_image_bases[i] = (uintptr_t)header;
        const struct uuid_command *uuid = NULL;
        if (header != NULL) {
            const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
            for (uint32_t c = 0; c < header->ncmds; c++) {
                const struct load_command *cmd = (const struct load_command *)cursor;
                if (cmd->cmd == LC_UUID) {
                    uuid = (const struct uuid_command *)cmd;
                    break;
                }
                cursor += cmd->cmdsize;
            }
        }
        if (uuid != NULL) {
            memcpy(g_frame.image_uuids[i], uuid->uuid, 16);
        } else {
            memset(g_frame.image_uuids[i], 0, 16);
        }
    }

    // 六个致命信号：Swift 的 fatalError 走 SIGTRAP/SIGILL，ObjC 异常走 SIGABRT。
    const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        signal(signals[i], moo_crash_handle);
    }

    return 0;
}

static uint32_t image_index_for(uintptr_t addr) {
    uint32_t best = 0;
    for (uint32_t i = 0; i < g_image_count; i++) {
        if (g_image_bases[i] != 0 && addr >= g_image_bases[i]) {
            best = i;
        }
    }
    return best;
}

void moo_crash_handle(int sig) {
    if (g_fd < 0) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }

    memset(&g_frame, 0, sizeof(g_frame));
    g_frame.magic = MOO_CRASH_MAGIC;
    g_frame.version = MOO_CRASH_VERSION;
    g_frame.kind = 1;
    g_frame.sig = sig;
    g_frame.image_count = g_image_count;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    g_frame.timestamp_ms = (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);

    void *frames[MOO_CRASH_MAX_DEPTH];
    int depth = backtrace(frames, MOO_CRASH_MAX_DEPTH);
    if (depth > 0) {
        g_frame.depth = (uint32_t)depth;
        for (int i = 0; i < depth; i++) {
            uintptr_t addr = (uintptr_t)frames[i];
            uint32_t idx = image_index_for(addr);
            g_frame.image_index[i] = (uint8_t)idx;
            g_frame.offsets[i] = addr - g_image_bases[idx];
        }
    }

    // 一次写完，避免半条记录。
    ssize_t ignored = write(g_fd, &g_frame, sizeof(g_frame));
    (void)ignored;

    // 恢复默认处理并重新抛出：系统照常生成崩溃报告，用户的崩溃对话框不受影响。
    signal(sig, SIG_DFL);
    raise(sig);
}

size_t moo_crash_read(const char *path, moo_crash_frame *out, size_t max) {
    if (path == NULL || out == NULL || max == 0) {
        return 0;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }

    size_t count = 0;
    moo_crash_frame frame;
    while (count < max) {
        ssize_t n = read(fd, &frame, sizeof(frame));
        if (n != (ssize_t)sizeof(frame) || frame.magic != MOO_CRASH_MAGIC) {
            break;
        }
        out[count++] = frame;
    }
    close(fd);
    return count;
}

void moo_crash_reset(const char *path) {
    if (path == NULL) {
        return;
    }
    if (g_fd >= 0) {
        close(g_fd);
        g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    } else {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            close(fd);
        }
    }
}
