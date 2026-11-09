#include "include/moo_crash_writer.h"

#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
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
static uintptr_t g_image_ends[MOO_CRASH_MAX_IMAGES];
/* UUID 必须单独缓存：g_frame 每次崩溃都会 memset，直接写在 g_frame 里会被清掉。 */
static uint8_t g_image_uuids[MOO_CRASH_MAX_IMAGES][16];
static uint32_t g_image_count = 0;
static volatile sig_atomic_t g_handling = 0;
/* ObjC 未捕获异常最后会 abort() 成 SIGABRT；Swift 侧既然已经落盘，就别再写一条。 */
static volatile sig_atomic_t g_exception_captured = 0;

/*
 * 每个 image 的结束地址。没有它，image_index_for 只能按「最后一个基址小于 addr 的
 * image」猜，地址落在两个 image 之间时会归错 image，算出看似合理的错误偏移。
 */
static uintptr_t image_end_for(const struct mach_header *header, intptr_t slide) {
    if (header == NULL) {
        return 0;
    }
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    uintptr_t end = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            uintptr_t segment_end = (uintptr_t)(seg->vmaddr + seg->vmsize) + (uintptr_t)slide;
            if (segment_end > end) {
                end = segment_end;
            }
        }
        cursor += cmd->cmdsize;
    }
    return end;
}

int moo_crash_install(const char *path) {
    if (path == NULL) {
        return -1;
    }
    g_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (g_fd < 0) {
        return -1;
    }
    g_handling = 0;
    g_exception_captured = 0;

    // image 表只在启动时取一次：_dyld_image_count / _dyld_get_image_header 内部有锁，
    // 信号恰好落在持锁线程上会死锁，所以处理器里只读这份缓存。
    uint32_t total = _dyld_image_count();
    g_image_count = total < MOO_CRASH_MAX_IMAGES ? total : MOO_CRASH_MAX_IMAGES;
    for (uint32_t i = 0; i < g_image_count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        g_image_bases[i] = (uintptr_t)header;
        g_image_ends[i] = image_end_for(header, _dyld_get_image_vmaddr_slide(i));
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
            memcpy(g_image_uuids[i], uuid->uuid, 16);
        } else {
            memset(g_image_uuids[i], 0, 16);
        }
    }

    // 六个致命信号：Swift 的 fatalError 走 SIGTRAP/SIGILL，ObjC 异常走 SIGABRT。
    const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        signal(signals[i], moo_crash_handle);
    }

    return 0;
}

/* 返回包含 addr 的 image 下标；不在缓存的 image 里就返回哨兵，绝不猜。 */
static uint32_t image_index_for(uintptr_t addr) {
    for (uint32_t i = 0; i < g_image_count; i++) {
        if (g_image_bases[i] != 0 && addr >= g_image_bases[i] && addr < g_image_ends[i]) {
            return i;
        }
    }
    return MOO_CRASH_UNKNOWN_IMAGE;
}

void moo_crash_skip_signal_after_exception(void) {
    g_exception_captured = 1;
}

void moo_crash_handle(int sig) {
    if (g_exception_captured) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    // 处理过程中再次触发（例如 backtrace 自己出错）：立刻交还系统，不递归写。
    if (g_handling) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    g_handling = 1;

    if (g_fd < 0) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }

    memset(&g_frame, 0, sizeof(g_frame));
    memcpy(g_frame.image_uuids, g_image_uuids, sizeof(g_image_uuids));
    g_frame.magic = MOO_CRASH_MAGIC;
    g_frame.version = MOO_CRASH_VERSION;
    g_frame.kind = 1;
    g_frame.sig = sig;
    g_frame.image_count = g_image_count;
    g_frame.thread_id = (uint64_t)(uintptr_t)pthread_self();

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
            if (idx == MOO_CRASH_UNKNOWN_IMAGE) {
                // 不属于启动时缓存的 image：没有 UUID 就无法跨启动还原，
                // 留哨兵让读取端跳过，宁缺毋错。
                g_frame.image_index[i] = MOO_CRASH_UNKNOWN_IMAGE;
                g_frame.offsets[i] = 0;
            } else {
                g_frame.image_index[i] = (uint8_t)idx;
                g_frame.offsets[i] = addr - g_image_bases[idx];
            }
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

size_t moo_crash_read_last(const char *path, moo_crash_frame *out, size_t max) {
    if (path == NULL || out == NULL || max == 0) {
        return 0;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(moo_crash_frame)) {
        close(fd);
        return 0;
    }

    size_t total = (size_t)st.st_size / sizeof(moo_crash_frame);
    size_t skip = total > max ? total - max : 0;
    if (lseek(fd, (off_t)(skip * sizeof(moo_crash_frame)), SEEK_SET) < 0) {
        close(fd);
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
    g_handling = 0;
    g_exception_captured = 0;
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
