#import "DXLog.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#define DX_LOG_MAX_BYTES   (256 * 1024)
#define DX_LINE_MAX        1024
#define DX_BC_SIZE         192
#define DX_MAX_IMAGES      64
#define DX_MAX_FRAMES      48
#define DX_ALT_STACK_SIZE  (64 * 1024)
#define DX_KEEP_CRASHES    8

/* ======================================================================
 *  Trạng thái toàn cục
 * ====================================================================== */

static char g_root[512];
static char g_logPath[560];
static char g_logPath1[576];
static char g_crashDir[560];
static char g_bcPath[560];
static char g_header[512];

static int   g_logFd = -1;
static off_t g_logSize = 0;
static int   g_minLevel = DXLogLevelInfo;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;

static int   g_bcFd = -1;
static char  g_bcText[DX_BC_SIZE];
static os_unfair_lock g_bcLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_prevBreadcrumb = nil;

typedef struct {
    char      name[64];
    uintptr_t base;
    uintptr_t end;
} DXImage;

static DXImage g_images[DX_MAX_IMAGES];
static int     g_imageCount = 0;
static os_unfair_lock g_imgLock = OS_UNFAIR_LOCK_INIT;

static struct sigaction g_oldActions[NSIG];
static const int kSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS };
#define DX_SIGNAL_COUNT ((int)(sizeof(kSignals) / sizeof(kSignals[0])))

static int       g_handling = 0;
static pthread_t g_handlingThread;
static volatile int g_objcReported = 0;
static NSUncaughtExceptionHandler *g_prevExceptionHandler = NULL;

static const char kLevelChar[4] = { 'D', 'I', 'W', 'E' };

/* ======================================================================
 *  Ghi log thường (không qua queue: write() trực tiếp, an toàn khi crash)
 * ====================================================================== */

static void dx_rotate_locked(void) {
    if (g_logFd >= 0) close(g_logFd);
    rename(g_logPath, g_logPath1);
    g_logFd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    g_logSize = 0;
}

void DXLogSetMinLevel(DXLogLevel level) {
    g_minLevel = (int)level;
}

void DXLogWrite(DXLogLevel level, const char *tag, const char *fmt, ...) {
    if ((int)level < g_minLevel || g_logFd < 0) return;

    if (!fmt) return;
    char msg[DX_LINE_MAX - 96];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    time_t sec = ts.tv_sec;
    struct tm tmv;
    localtime_r(&sec, &tmv);
    char tbuf[24];
    strftime(tbuf, sizeof(tbuf), "%m-%d %H:%M:%S", &tmv);

    char line[DX_LINE_MAX];
    int n = snprintf(line, sizeof(line), "%s.%03d %c [%s] %s\n",
                     tbuf, (int)(ts.tv_nsec / 1000000), kLevelChar[(int)level & 3],
                     tag ? tag : "-", msg);
    if (n <= 0) return;
    if ((size_t)n >= sizeof(line)) {
        n = (int)sizeof(line) - 1;
        line[n - 1] = '\n';
    }

    os_unfair_lock_lock(&g_lock);
    if (g_logFd >= 0) {
        if (g_logSize + n > DX_LOG_MAX_BYTES) dx_rotate_locked();
        if (g_logFd >= 0) {
            ssize_t w = write(g_logFd, line, (size_t)n);
            if (w > 0) g_logSize += w;
        }
    }
    os_unfair_lock_unlock(&g_lock);

#ifdef DEBUG
    fputs(line, stderr);
#endif
}

/* ======================================================================
 *  Đăng ký image (để crash đổi địa chỉ -> tên module + offset)
 * ====================================================================== */

void DXLogRegisterImage(const char *name, const void *header) {
    if (!name || !header) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->magic != MH_MAGIC_64) return;

    uintptr_t size = 0;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmdsize < sizeof(struct load_command)) return;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                size = (uintptr_t)seg->vmsize;
                break;
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!size) return;

    os_unfair_lock_lock(&g_imgLock);
    int count = g_imageCount;
    int slot = -1;
    for (int i = 0; i < count; i++) {
        if (strncmp(g_images[i].name, name, sizeof(g_images[i].name)) == 0) { slot = i; break; }
    }
    BOOL isNew = (slot < 0);
    if (isNew) {
        if (count >= DX_MAX_IMAGES) { os_unfair_lock_unlock(&g_imgLock); return; }
        slot = count;
    }
    strlcpy(g_images[slot].name, name, sizeof(g_images[slot].name));
    g_images[slot].base = (uintptr_t)header;
    g_images[slot].end  = (uintptr_t)header + size;
    if (isNew) __atomic_store_n(&g_imageCount, count + 1, __ATOMIC_RELEASE);
    os_unfair_lock_unlock(&g_imgLock);

    DXLogWrite(DXLogLevelInfo, "image", "%s tại 0x%lx (text %lu byte)",
               name, (unsigned long)(uintptr_t)header, (unsigned long)size);
}

/* ======================================================================
 *  Breadcrumb: "đang làm gì" lưu ra file nhỏ, sống sót cả khi bị kill
 * ====================================================================== */

void DXBreadcrumbBegin(const char *plugin, const char *step) {
    if (g_bcFd < 0) return;
    char buf[DX_BC_SIZE];
    memset(buf, 0, sizeof(buf));
    snprintf(buf, sizeof(buf), "%s|%s", plugin ? plugin : "-", step ? step : "-");
    os_unfair_lock_lock(&g_bcLock);
    memcpy(g_bcText, buf, sizeof(buf));
    (void)pwrite(g_bcFd, buf, sizeof(buf), 0);
    os_unfair_lock_unlock(&g_bcLock);
}

void DXBreadcrumbEnd(void) {
    if (g_bcFd < 0) return;
    char zero[DX_BC_SIZE];
    memset(zero, 0, sizeof(zero));
    os_unfair_lock_lock(&g_bcLock);
    memset(g_bcText, 0, sizeof(g_bcText));
    (void)pwrite(g_bcFd, zero, sizeof(zero), 0);
    os_unfair_lock_unlock(&g_bcLock);
}

/* ======================================================================
 *  Bộ ghi an toàn trong signal handler (không malloc, không printf)
 * ====================================================================== */

typedef struct {
    int    fd;
    size_t n;
    char   b[1024];
} DXOut;

static void o_flush(DXOut *o) {
    if (o->n) {
        (void)write(o->fd, o->b, o->n);
        o->n = 0;
    }
}

static void o_str(DXOut *o, const char *s) {
    if (!s) return;
    while (*s) {
        if (o->n == sizeof(o->b)) o_flush(o);
        o->b[o->n++] = *s++;
    }
}

static void o_dec(DXOut *o, long v) {
    char t[24];
    int i = 0;
    unsigned long u;
    if (v < 0) { o_str(o, "-"); u = (unsigned long)(-(v + 1)) + 1UL; }
    else u = (unsigned long)v;
    if (!u) t[i++] = '0';
    while (u) { t[i++] = (char)('0' + (u % 10)); u /= 10; }
    char r[24];
    int j = 0;
    while (i) r[j++] = t[--i];
    r[j] = 0;
    o_str(o, r);
}

static void o_hex(DXOut *o, uintptr_t v) {
    static const char digits[] = "0123456789abcdef";
    char t[20];
    int i = 0;
    if (!v) t[i++] = '0';
    while (v) { t[i++] = digits[v & 15]; v >>= 4; }
    char r[24];
    int j = 0;
    r[j++] = '0';
    r[j++] = 'x';
    while (i) r[j++] = t[--i];
    r[j] = 0;
    o_str(o, r);
}

static inline uintptr_t dx_strip(uintptr_t p) {
#if defined(__has_feature)
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)p, ptrauth_key_return_address);
#endif
#endif
    return p;
}

static const char *dx_sig_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGABRT: return "SIGABRT";
        case SIGFPE:  return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        case SIGSYS:  return "SIGSYS";
        default:      return "SIG?";
    }
}

static void dx_write_addr(DXOut *o, int idx, uintptr_t addr) {
    o_str(o, "  #");
    o_dec(o, idx);
    o_str(o, " ");
    o_hex(o, addr);
    int n = __atomic_load_n(&g_imageCount, __ATOMIC_ACQUIRE);
    for (int i = 0; i < n; i++) {
        if (addr >= g_images[i].base && addr < g_images[i].end) {
            o_str(o, " ");
            o_str(o, g_images[i].name);
            o_str(o, " +");
            o_hex(o, addr - g_images[i].base);
            break;
        }
    }
    o_str(o, "\n");
}

static void dx_write_modules(DXOut *o) {
    int n = __atomic_load_n(&g_imageCount, __ATOMIC_ACQUIRE);
    o_str(o, "\nModules (name, base):\n");
    for (int i = 0; i < n; i++) {
        o_str(o, "  ");
        o_str(o, g_images[i].name);
        o_str(o, " ");
        o_hex(o, g_images[i].base);
        o_str(o, "\n");
    }
}

/* Dựng đường dẫn crash-<unix time>.txt mà không dùng snprintf */
static void dx_crash_path(char *out, size_t cap) {
    size_t n = 0;
    const char *p = g_crashDir;
    while (*p && n + 1 < cap) out[n++] = *p++;
    p = "/crash-";
    while (*p && n + 1 < cap) out[n++] = *p++;
    char t[24];
    int i = 0;
    unsigned long u = (unsigned long)time(NULL);
    if (!u) t[i++] = '0';
    while (u) { t[i++] = (char)('0' + (u % 10)); u /= 10; }
    while (i && n + 1 < cap) out[n++] = t[--i];
    p = ".txt";
    while (*p && n + 1 < cap) out[n++] = *p++;
    out[n] = 0;
}

/* Đi theo chuỗi frame pointer (arm64). Kiểm tra từng bước để không crash lần hai. */
static void dx_walk(DXOut *o, void *ctx) {
#if defined(__arm64__)
    ucontext_t *uc = (ucontext_t *)ctx;
    if (!uc || !uc->uc_mcontext) {
        o_str(o, "  (không có context)\n");
        return;
    }
    uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    uintptr_t lr = (uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
    uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    uintptr_t sp = (uintptr_t)arm_thread_state64_get_sp(uc->uc_mcontext->__ss);

    pthread_t self = pthread_self();
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(self);

    int idx = 0;
    dx_write_addr(o, idx++, pc);
    if (lr) dx_write_addr(o, idx++, lr);

    uintptr_t prev = 0;
    int first = 1;
    while (idx < DX_MAX_FRAMES && top && fp >= sp && fp + 16 <= top && (fp & 7) == 0 && fp > prev) {
        uintptr_t *frame = (uintptr_t *)fp;
        uintptr_t next = frame[0];
        uintptr_t ret = dx_strip(frame[1]);
        if (!ret) break;
        if (!(first && ret == lr)) dx_write_addr(o, idx++, ret);
        first = 0;
        prev = fp;
        fp = next;
    }
#else
    (void)ctx;
    o_str(o, "  (backtrace chỉ hỗ trợ arm64)\n");
#endif
}

/* ======================================================================
 *  Signal handler
 * ====================================================================== */

static void dx_signal_handler(int sig, siginfo_t *info, void *ctx) {
    pthread_t self = pthread_self();
    if (__atomic_exchange_n(&g_handling, 1, __ATOMIC_ACQ_REL)) {
        /* Crash lồng nhau, hoặc luồng khác crash cùng lúc */
        if (pthread_equal(self, g_handlingThread)) _exit(128 + sig);
        sleep(3);
        _exit(128 + sig);
    }
    g_handlingThread = self;

    if (!g_objcReported) {
        char path[640];
        dx_crash_path(path, sizeof(path));
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            DXOut o;
            o.fd = fd;
            o.n = 0;
            o_str(&o, "DYNEX crash report\n");
            o_str(&o, g_header);
            o_str(&o, "\nSignal: ");
            o_str(&o, dx_sig_name(sig));
            o_str(&o, " (");
            o_dec(&o, sig);
            o_str(&o, ") code=");
            o_dec(&o, info ? info->si_code : 0);
            o_str(&o, "\nFault address: ");
            o_hex(&o, info ? (uintptr_t)info->si_addr : 0);
            o_str(&o, "\nThread: ");
            o_str(&o, pthread_main_np() ? "main" : "background");
            o_str(&o, "\nActive: ");
            o_str(&o, g_bcText[0] ? g_bcText : "(none)");
            o_str(&o, "\n\nBacktrace:\n");
            dx_walk(&o, ctx);
            dx_write_modules(&o);
            o_flush(&o);
            close(fd);
        }
    }

    /* Trả quyền cho handler trước đó (thường là mặc định của hệ thống) */
    if (sig > 0 && sig < NSIG) sigaction(sig, &g_oldActions[sig], NULL);
    pthread_kill(self, sig);
    __atomic_store_n(&g_handling, 0, __ATOMIC_RELEASE);
}

/* ======================================================================
 *  Ngoại lệ Objective-C chưa được bắt
 * ====================================================================== */

static void dx_format_addr(NSMutableString *s, int idx, uintptr_t addr) {
    char buf[200];
    int n = __atomic_load_n(&g_imageCount, __ATOMIC_ACQUIRE);
    const char *mod = NULL;
    uintptr_t off = 0;
    for (int i = 0; i < n; i++) {
        if (addr >= g_images[i].base && addr < g_images[i].end) {
            mod = g_images[i].name;
            off = addr - g_images[i].base;
            break;
        }
    }
    if (mod) snprintf(buf, sizeof(buf), "  #%d 0x%lx %s +0x%lx\n", idx, (unsigned long)addr, mod, (unsigned long)off);
    else     snprintf(buf, sizeof(buf), "  #%d 0x%lx\n", idx, (unsigned long)addr);
    [s appendFormat:@"%s", buf];
}

static void dx_exception_handler(NSException *ex) {
    g_objcReported = 1;
    @try {
        char path[640];
        dx_crash_path(path, sizeof(path));

        NSMutableString *s = [NSMutableString string];
        [s appendString:@"DYNEX crash report\n"];
        [s appendFormat:@"%s\n", g_header];
        [s appendFormat:@"ObjC exception: %@\nReason: %@\n", ex.name, ex.reason];
        [s appendFormat:@"Active: %s\n\nBacktrace:\n", g_bcText[0] ? g_bcText : "(none)"];

        int idx = 0;
        for (NSNumber *a in ex.callStackReturnAddresses) {
            if (idx >= DX_MAX_FRAMES) break;
            dx_format_addr(s, idx++, (uintptr_t)a.unsignedLongLongValue);
        }
        [s appendString:@"\nSymbols:\n"];
        idx = 0;
        for (NSString *sym in ex.callStackSymbols) {
            if (idx++ >= DX_MAX_FRAMES) break;
            [s appendFormat:@"  %@\n", sym];
        }
        [s appendString:@"\nModules (name, base):\n"];
        int n = __atomic_load_n(&g_imageCount, __ATOMIC_ACQUIRE);
        for (int i = 0; i < n; i++) {
            [s appendFormat:@"  %s 0x%lx\n", g_images[i].name, (unsigned long)g_images[i].base];
        }
        [s writeToFile:[NSString stringWithUTF8String:path]
            atomically:NO encoding:NSUTF8StringEncoding error:nil];
        DXLogWrite(DXLogLevelError, "crash", "Ngoại lệ ObjC: %s - %s | đang chạy: %s",
                   ex.name.UTF8String, ex.reason.UTF8String, g_bcText[0] ? g_bcText : "(none)");
    } @catch (__unused id e) {
    }
    if (g_prevExceptionHandler) g_prevExceptionHandler(ex);
}

/* ======================================================================
 *  Cài / cài lại bộ bắt crash
 * ====================================================================== */

static void dx_install_altstack(void) {
    stack_t cur;
    if (sigaltstack(NULL, &cur) == 0 && !(cur.ss_flags & SS_DISABLE)) return;  /* đã có sẵn */
    stack_t ss;
    ss.ss_sp = malloc(DX_ALT_STACK_SIZE);
    ss.ss_size = DX_ALT_STACK_SIZE;
    ss.ss_flags = 0;
    if (ss.ss_sp) sigaltstack(&ss, NULL);
}

static void dx_install_signals(void) {
    for (int i = 0; i < DX_SIGNAL_COUNT; i++) {
        int sig = kSignals[i];
        struct sigaction cur;
        if (sigaction(sig, NULL, &cur) != 0) continue;
        if ((cur.sa_flags & SA_SIGINFO) && cur.sa_sigaction == dx_signal_handler) continue;
        g_oldActions[sig] = cur;
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = dx_signal_handler;
        sigfillset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigaction(sig, &sa, NULL);
    }
}

static void dx_install_exception(void) {
    NSUncaughtExceptionHandler *cur = NSGetUncaughtExceptionHandler();
    if (cur == dx_exception_handler) return;
    g_prevExceptionHandler = cur;
    NSSetUncaughtExceptionHandler(&dx_exception_handler);
}

void DXLogEnsureHandlers(void) {
    dx_install_signals();
    dx_install_exception();
}

/* ======================================================================
 *  Khởi tạo
 * ====================================================================== */

NSString *DXLogRootDirectory(void) {
    return g_root[0] ? [NSString stringWithUTF8String:g_root] : NSTemporaryDirectory();
}

void DXLogSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            if (!docs.length) docs = NSTemporaryDirectory();
            NSString *root  = [docs stringByAppendingPathComponent:@"DYNEX"];
            NSString *logs  = [root stringByAppendingPathComponent:@"logs"];
            NSString *crash = [root stringByAppendingPathComponent:@"crashes"];

            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:logs  withIntermediateDirectories:YES attributes:nil error:nil];
            [fm createDirectoryAtPath:crash withIntermediateDirectories:YES attributes:nil error:nil];

            strlcpy(g_root, root.fileSystemRepresentation, sizeof(g_root));
            snprintf(g_logPath,  sizeof(g_logPath),  "%s/dynex.log",   logs.fileSystemRepresentation);
            snprintf(g_logPath1, sizeof(g_logPath1), "%s/dynex.log.1", logs.fileSystemRepresentation);
            snprintf(g_bcPath,   sizeof(g_bcPath),   "%s/session.bc",  logs.fileSystemRepresentation);
            strlcpy(g_crashDir, crash.fileSystemRepresentation, sizeof(g_crashDir));

            struct utsname u;
            uname(&u);
            NSBundle *b = [NSBundle mainBundle];
            NSString *bid = b.bundleIdentifier ?: @"?";
            NSString *ver = [b.infoDictionary objectForKey:@"CFBundleShortVersionString"] ?: @"?";
            snprintf(g_header, sizeof(g_header), "App: %s %s | OS: %s | Device: %s",
                     bid.UTF8String, ver.UTF8String,
                     [NSProcessInfo processInfo].operatingSystemVersionString.UTF8String,
                     u.machine);

            /* Đọc breadcrumb còn sót của lần chạy trước rồi xoá */
            g_bcFd = open(g_bcPath, O_RDWR | O_CREAT, 0644);
            if (g_bcFd >= 0) {
                char buf[DX_BC_SIZE];
                memset(buf, 0, sizeof(buf));
                ssize_t r = pread(g_bcFd, buf, sizeof(buf) - 1, 0);
                if (r > 0 && buf[0]) {
                    g_prevBreadcrumb = [NSString stringWithUTF8String:buf];
                }
                memset(buf, 0, sizeof(buf));
                (void)pwrite(g_bcFd, buf, sizeof(buf), 0);
            }

            g_logFd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (g_logFd >= 0) {
                struct stat st;
                if (fstat(g_logFd, &st) == 0) g_logSize = st.st_size;
            }

            /* Ghi nhận main executable và chính core */
            const void *exeHeader = _dyld_get_image_header(0);
            if (exeHeader) DXLogRegisterImage("app", exeHeader);
            Dl_info info;
            if (dladdr((const void *)&DXLogSetup, &info) && info.dli_fbase) {
                DXLogRegisterImage("DYNEX-core", info.dli_fbase);
            }

            signal(SIGPIPE, SIG_IGN);
            dx_install_altstack();
            DXLogEnsureHandlers();

            DXLogWrite(DXLogLevelInfo, "core", "DYNEX khởi động | %s", g_header);
        }
    });
}

/* ======================================================================
 *  Báo cáo lần chạy trước, đọc log, xoá log (cho UI)
 * ====================================================================== */

static NSArray<NSString *> *dx_list_crash_files(BOOL unseenOnly) {
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithUTF8String:g_crashDir] error:nil] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in all) {
        if (![f hasPrefix:@"crash-"] || ![f hasSuffix:@".txt"]) continue;
        BOOL seen = [f hasSuffix:@".seen.txt"];
        if (unseenOnly && seen) continue;
        [out addObject:f];
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

NSString *_Nullable DXLogTakePreviousSessionReport(void) {
    if (!g_crashDir[0]) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSString stringWithUTF8String:g_crashDir];
    NSString *result = nil;

    NSArray<NSString *> *unseen = dx_list_crash_files(YES);
    if (unseen.count) {
        NSString *newest = unseen.lastObject;
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:newest]];
        NSString *full = d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : @"";
        if (full.length > 4000) full = [full substringToIndex:4000];
        result = [NSString stringWithFormat:@"Lần chạy trước bị crash (%@):\n%@", newest, full];

        for (NSString *f in unseen) {
            NSString *seenName = [[f stringByDeletingPathExtension] stringByAppendingString:@".seen.txt"];
            [fm moveItemAtPath:[dir stringByAppendingPathComponent:f]
                        toPath:[dir stringByAppendingPathComponent:seenName] error:nil];
        }
    } else if (g_prevBreadcrumb.length) {
        result = [NSString stringWithFormat:
                  @"Lần chạy trước kết thúc bất thường khi đang: %@\n"
                  @"(Không có báo cáo crash. Có thể do hệ thống đóng app vì quá tải hoặc treo, hoặc bị thoát đột ngột.)",
                  g_prevBreadcrumb];
    }
    g_prevBreadcrumb = nil;

    NSArray<NSString *> *all = dx_list_crash_files(NO);
    if (all.count > DX_KEEP_CRASHES) {
        for (NSUInteger i = 0; i < all.count - DX_KEEP_CRASHES; i++) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:all[i]] error:nil];
        }
    }
    if (result) DXLogWrite(DXLogLevelWarn, "core", "Phát hiện sự cố lần chạy trước");
    return result;
}

NSString *DXLogReadTail(NSUInteger maxBytes) {
    if (!g_logPath[0] || maxBytes == 0) return @"";
    int fd = open(g_logPath, O_RDONLY);
    if (fd < 0) return @"";
    off_t size = lseek(fd, 0, SEEK_END);
    if (size <= 0) { close(fd); return @""; }
    off_t start = size > (off_t)maxBytes ? size - (off_t)maxBytes : 0;
    size_t len = (size_t)(size - start);
    NSMutableData *buf = [NSMutableData dataWithLength:len];
    ssize_t r = pread(fd, buf.mutableBytes, len, start);
    close(fd);
    if (r <= 0) return @"";
    buf.length = (NSUInteger)r;

    /* Bỏ dòng bị cắt dở ở đầu (cũng đảm bảo không cắt giữa ký tự UTF-8) */
    const uint8_t *p = buf.bytes;
    NSUInteger skip = 0;
    if (start > 0) {
        while (skip < buf.length && p[skip] != '\n') skip++;
        if (skip < buf.length) skip++;
    }
    NSData *slice = [buf subdataWithRange:NSMakeRange(skip, buf.length - skip)];
    return [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding] ?: @"";
}

void DXLogClear(void) {
    os_unfair_lock_lock(&g_lock);
    if (g_logFd >= 0) {
        (void)ftruncate(g_logFd, 0);
        g_logSize = 0;
    }
    if (g_logPath1[0]) unlink(g_logPath1);
    os_unfair_lock_unlock(&g_lock);

    if (g_crashDir[0]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [NSString stringWithUTF8String:g_crashDir];
        for (NSString *f in dx_list_crash_files(NO)) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    }
    DXLogWrite(DXLogLevelInfo, "core", "Đã xoá nhật ký");
}
