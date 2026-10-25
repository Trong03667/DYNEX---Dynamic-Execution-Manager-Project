#import "DXLoader.h"
#import "DXLog.h"
#import "dynex.h"

#import <UIKit/UIKit.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <sys/stat.h>
#include <unistd.h>

NSNotificationName const DXLoaderDidChangeNotification = @"DXLoaderDidChangeNotification";

#define DX_MAX_PLUGINS         64
#define DX_MAX_PLUGIN_BYTES    (64ULL * 1024ULL * 1024ULL)
#define DX_MAX_MANIFEST_BYTES  (64 * 1024)
#define DX_MAX_CONTROLS        32
#define DX_SAFE_SECONDS        60

#define DXC(s) [[(s) stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] UTF8String]

typedef void        (*DXInitFn)(const DynexHost *);
typedef const char *(*DXManifestFn)(void);
typedef void        (*DXSetEnabledFn)(bool);
typedef void        (*DXSetOptionFn)(const char *, double);
typedef void        (*DXActionFn)(const char *);
typedef void        (*DXOpenUIFn)(void);

/* ======================================================================
 *  Tiện ích C
 * ====================================================================== */

static void dx_host_log(DynexLogLevel level, const char *pluginId, const char *message) {
    int l = (int)level;
    if (l < 0) l = 0;
    if (l > 3) l = 3;
    DXLogWrite((DXLogLevel)l, (pluginId && pluginId[0]) ? pluginId : "plugin", "%s", message ? message : "");
}
static const DynexHost kHost = { DYNEX_API_VERSION, dx_host_log };

static BOOL dx_valid_id(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = s.length;
    if (len == 0 || len > 64) return NO;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                  c == '.' || c == '_' || c == '-';
        if (!ok) return NO;
    }
    return YES;
}

static BOOL dx_is_number(id v) {
    return [v isKindOfClass:[NSNumber class]] && isfinite([(NSNumber *)v doubleValue]);
}

static double dx_clamp_option(NSDictionary *control, double v) {
    if (!isfinite(v)) v = 0;
    NSString *kind = control[@"kind"];
    if ([kind isEqualToString:@"toggle"]) return v != 0 ? 1.0 : 0.0;
    double lo = [control[@"min"] doubleValue], hi = [control[@"max"] doubleValue];
    return fmin(fmax(v, lo), hi);
}

/* Chạy 1 lời gọi vào plugin, bắt ngoại lệ ObjC để không kéo sập game */
static NSString *dx_guard(void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    } @catch (id other) {
        return @"Ngoại lệ không xác định";
    }
    return nil;
}

/* Marker "đang làm việc nguy hiểm": nếu crash giữa chừng, lần sau cô lập file đó */
static char g_markerPath[600];

static void dx_marker_set(NSString *file, const char *op) {
    if (!g_markerPath[0]) return;
    char buf[400];
    int n = snprintf(buf, sizeof(buf), "%s\t%s", file.UTF8String, op);
    if (n <= 0) return;
    int fd = open(g_markerPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    (void)write(fd, buf, strlen(buf));
    close(fd);
}
static void dx_marker_clear(void) {
    if (g_markerPath[0]) unlink(g_markerPath);
}
static NSString *dx_marker_read(void) {
    if (!g_markerPath[0]) return nil;
    NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:g_markerPath]];
    if (!d.length || d.length > 1024) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

/* Kiểm tra sơ bộ file trước khi dlopen */
static NSString *dx_check_macho(NSString *path, unsigned long long *sizeOut) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return @"Không tìm thấy file";
    if (!S_ISREG(st.st_mode)) return @"Không phải file thường";
    if (sizeOut) *sizeOut = (unsigned long long)st.st_size;
    if (st.st_size < 512) return @"File quá nhỏ, không phải dylib";
    if ((unsigned long long)st.st_size > DX_MAX_PLUGIN_BYTES) return @"File quá lớn (hơn 64 MB)";

    uint32_t head[4] = {0, 0, 0, 0};
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return @"Không đọc được file";
    ssize_t r = read(fd, head, sizeof(head));
    close(fd);
    if (r != (ssize_t)sizeof(head)) return @"Không đọc được tiêu đề file";

    if (head[0] == FAT_CIGAM || head[0] == FAT_MAGIC) return nil;
    if (head[0] == MH_MAGIC_64) {
        if ((cpu_type_t)head[1] != CPU_TYPE_ARM64) return @"Không phải arm64 (iPhone cần arm64)";
        if (head[3] != MH_DYLIB) return @"Không phải dylib (sai loại file Mach-O)";
        return nil;
    }
    return @"Không phải file Mach-O 64-bit";
}

static NSString *dx_dlopen_hint(NSString *raw) {
    NSString *l = raw.lowercaseString;
    if ([l containsString:@"code signature"] || [l containsString:@"not valid for use in process"] ||
        [l containsString:@"different team"] || [l containsString:@"library load disallowed"]) {
        return @"Dylib chưa ký đúng: phải ký cùng chứng chỉ với IPA (Esign).";
    }
    if ([l containsString:@"symbol not found"]) {
        return @"Dylib cần hàm hoặc thư viện mà game không có (thiếu symbol).";
    }
    if ([l containsString:@"no such file"] || [l containsString:@"image not found"]) {
        return @"Không tìm thấy file hoặc thư viện phụ thuộc.";
    }
    if ([l containsString:@"mach-o"] || [l containsString:@"architecture"] || [l containsString:@"incompatible"]) {
        return @"Sai kiến trúc hoặc iOS tối thiểu của dylib cao hơn máy.";
    }
    return nil;
}

static NSString *dx_clean_filename(NSString *name) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length && out.length < 80; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                  c == '.' || c == '_' || c == '-' || c == ' ' || c == '(' || c == ')';
        [out appendFormat:@"%C", ok ? c : (unichar)'_'];
    }
    while ([out hasPrefix:@"."]) [out deleteCharactersInRange:NSMakeRange(0, 1)];
    return out;
}

/* Kiểm tra và làm sạch danh sách controls từ manifest. Trả nil + err nếu sai. */
static NSArray<NSDictionary *> *dx_sanitize_controls(id raw, NSString **err) {
    if (raw == nil || raw == [NSNull null]) return @[];
    if (![raw isKindOfClass:[NSArray class]]) { *err = @"\"controls\" phải là mảng"; return nil; }
    NSArray *arr = raw;
    if (arr.count > DX_MAX_CONTROLS) { *err = @"Quá nhiều control (tối đa 32)"; return nil; }

    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) { *err = @"Control không hợp lệ"; return nil; }
        NSDictionary *c = item;
        NSString *cid = c[@"id"], *kind = c[@"kind"], *label = c[@"label"];
        if (!dx_valid_id(cid)) { *err = @"Control có id sai (chỉ dùng chữ, số, . _ -)"; return nil; }
        if ([seen containsObject:cid]) { *err = [NSString stringWithFormat:@"Trùng id control: %@", cid]; return nil; }
        [seen addObject:cid];
        if (![label isKindOfClass:[NSString class]] || label.length == 0 || label.length > 64) {
            *err = [NSString stringWithFormat:@"Control %@ thiếu hoặc sai nhãn", cid]; return nil;
        }
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:@{@"id": cid, @"label": label}];
        if ([kind isEqualToString:@"button"]) {
            d[@"kind"] = @"button";
        } else if ([kind isEqualToString:@"toggle"]) {
            d[@"kind"] = @"toggle";
            d[@"value"] = @([c[@"value"] respondsToSelector:@selector(boolValue)] ? ([c[@"value"] boolValue] ? 1 : 0) : 0);
        } else if ([kind isEqualToString:@"slider"]) {
            if (!dx_is_number(c[@"min"]) || !dx_is_number(c[@"max"]) || !dx_is_number(c[@"step"])) {
                *err = [NSString stringWithFormat:@"Slider %@ thiếu min/max/step", cid]; return nil;
            }
            double lo = [c[@"min"] doubleValue], hi = [c[@"max"] doubleValue], st = [c[@"step"] doubleValue];
            if (!(lo < hi) || !(st > 0)) { *err = [NSString stringWithFormat:@"Slider %@ có min/max/step sai", cid]; return nil; }
            double v = dx_is_number(c[@"value"]) ? [c[@"value"] doubleValue] : lo;
            d[@"kind"] = @"slider";
            d[@"min"] = @(lo); d[@"max"] = @(hi); d[@"step"] = @(st);
            d[@"value"] = @(fmin(fmax(v, lo), hi));
            NSString *unit = c[@"unit"];
            d[@"unit"] = ([unit isKindOfClass:[NSString class]] && unit.length <= 8) ? unit : @"";
        } else {
            *err = [NSString stringWithFormat:@"Control %@ có kind sai", cid]; return nil;
        }
        [out addObject:d];
    }
    return out;
}

/* ======================================================================
 *  DXPlugin
 * ====================================================================== */

@interface DXPlugin ()
@property (nonatomic, readwrite, copy) NSString *fileName;
@property (nonatomic, readwrite, copy) NSString *pluginId;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *version;
@property (nonatomic, readwrite) BOOL ownUI;
@property (nonatomic, readwrite, copy) NSString *bubbleText;
@property (nonatomic, readwrite) double hue;
@property (nonatomic, readwrite, copy) NSArray<NSDictionary *> *controls;
@property (nonatomic, readwrite) DXPluginState state;
@property (nonatomic, readwrite, copy, nullable) NSString *errorMessage;
@property (nonatomic, readwrite) BOOL enabled;
@property (nonatomic, readwrite) unsigned long long fileSize;
@property (nonatomic) void *handle;
@property (nonatomic) DXSetEnabledFn fnSetEnabled;
@property (nonatomic) DXSetOptionFn fnSetOption;
@property (nonatomic) DXActionFn fnAction;
@property (nonatomic) DXOpenUIFn fnOpenUI;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *options;
- (instancetype)initWithFileName:(NSString *)fileName;
@end

@implementation DXPlugin
- (instancetype)initWithFileName:(NSString *)fileName {
    if ((self = [super init])) {
        _fileName = [fileName copy];
        _pluginId = [fileName copy];
        _name = [fileName.stringByDeletingPathExtension copy];
        _version = @"";
        _bubbleText = @"";
        _hue = 260;
        _controls = @[];
        _options = [NSMutableDictionary dictionary];
        _state = DXPluginStateFailed;
    }
    return self;
}
- (double)valueForOption:(NSString *)optionId {
    return [self.options[optionId] doubleValue];
}
@end

/* ======================================================================
 *  DXLoader
 * ====================================================================== */

@interface DXLoader () {
    NSMutableArray<DXPlugin *> *_plugins;
    NSMutableDictionary *_config;
    NSMutableArray<NSString *> *_pendingFiles;
    NSMutableSet<NSString *> *_retiredFiles;
    NSMutableSet<NSString *> *_retiredIds;
    NSString *_pluginsDir;
    NSString *_configPath;
    NSString *_recoveryNote;
    dispatch_queue_t _copyQueue;
    dispatch_queue_t _cfgQueue;
    BOOL _started;
    BOOL _savePending;
    BOOL _safeMode;
    BOOL _loading;
}
@end

@implementation DXLoader

+ (instancetype)shared {
    static DXLoader *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[DXLoader alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _plugins = [NSMutableArray array];
        _pendingFiles = [NSMutableArray array];
        _retiredFiles = [NSMutableSet set];
        _retiredIds = [NSMutableSet set];
        _config = [NSMutableDictionary dictionary];
        _copyQueue = dispatch_queue_create("dynex.copy", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _cfgQueue  = dispatch_queue_create("dynex.cfg",  dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _pluginsDir = @"";
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(appWillBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(appWillBackground:) name:UIApplicationWillTerminateNotification object:nil];
    }
    return self;
}

- (NSArray<DXPlugin *> *)plugins { return [_plugins copy]; }
- (NSString *)pluginsDirectory { return _pluginsDir; }
- (BOOL)safeMode { return _safeMode; }
- (NSString *)recoveryNote { return _recoveryNote; }
- (BOOL)loading { return _loading; }

- (BOOL)requireMain:(const char *)what {
    if ([NSThread isMainThread]) return YES;
    DXLOGE("loader", "%s phải gọi trên main thread, đã bỏ qua", what);
    return NO;
}

- (void)postChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:DXLoaderDidChangeNotification object:self];
}

/* ---------------- Cấu hình ---------------- */

static NSMutableDictionary *dx_normalize_config(id raw) {
    NSMutableDictionary *root = [raw isKindOfClass:[NSMutableDictionary class]] ? raw : [NSMutableDictionary dictionary];
    if (![root[@"plugins"] isKindOfClass:[NSMutableDictionary class]]) root[@"plugins"] = [NSMutableDictionary dictionary];
    if (![root[@"quarantine"] isKindOfClass:[NSMutableDictionary class]]) root[@"quarantine"] = [NSMutableDictionary dictionary];
    if (![root[@"crashStreak"] isKindOfClass:[NSNumber class]]) root[@"crashStreak"] = @0;
    root[@"version"] = @1;
    return root;
}

- (void)loadConfig {
    NSData *d = [NSData dataWithContentsOfFile:_configPath];
    id parsed = nil;
    if (d.length) {
        NSError *e = nil;
        parsed = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:&e];
        if (!parsed || ![parsed isKindOfClass:[NSDictionary class]]) {
            DXLOGW("loader", "config.json hỏng, tạo mới (bản cũ lưu thành config.json.bad)");
            [[NSFileManager defaultManager] removeItemAtPath:[_configPath stringByAppendingString:@".bad"] error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:_configPath toPath:[_configPath stringByAppendingString:@".bad"] error:nil];
            parsed = nil;
        }
    }
    _config = dx_normalize_config(parsed);
}

- (void)writeConfigSync:(BOOL)sync {
    NSData *data = nil;
    @try {
        data = [NSJSONSerialization dataWithJSONObject:_config options:NSJSONWritingPrettyPrinted error:nil];
    } @catch (id e) {
        data = nil;
    }
    if (!data) { DXLOGE("loader", "Không ghi được config (dữ liệu không hợp lệ)"); return; }
    NSString *path = _configPath;
    void (^work)(void) = ^{
        NSError *err = nil;
        if (![data writeToFile:path options:NSDataWritingAtomic error:&err]) {
            DXLOGE("loader", "Ghi config lỗi: %s", DXC(err.localizedDescription ?: @"?"));
        }
    };
    if (sync) dispatch_sync(_cfgQueue, work); else dispatch_async(_cfgQueue, work);
}

- (void)scheduleSave {
    if (_savePending) return;
    _savePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_savePending = NO;
        [self writeConfigSync:NO];
    });
}

- (void)flushConfig {
    if (![self requireMain:"flushConfig"] || !_started) return;
    _savePending = NO;
    [self writeConfigSync:YES];
}

- (void)appWillBackground:(NSNotification *)n {
    if (_started) [self writeConfigSync:YES];
}

- (NSMutableDictionary *)configForId:(NSString *)pid {
    NSMutableDictionary *all = _config[@"plugins"];
    id e = all[pid];
    if (![e isKindOfClass:[NSMutableDictionary class]]) {
        e = [NSMutableDictionary dictionary];
        all[pid] = e;
    }
    return e;
}

- (NSMutableDictionary *)optionsConfigForId:(NSString *)pid {
    NSMutableDictionary *pc = [self configForId:pid];
    id o = pc[@"options"];
    if (![o isKindOfClass:[NSMutableDictionary class]]) {
        o = [NSMutableDictionary dictionary];
        pc[@"options"] = o;
    }
    return o;
}

/* ---------------- Khởi động ---------------- */

- (void)startWithPreviousSessionReport:(NSString *)report {
    if (![self requireMain:"start"] || _started) return;
    _started = YES;

    NSString *root = DXLogRootDirectory();
    _pluginsDir = [root stringByAppendingPathComponent:@"plugins"];
    _configPath = [root stringByAppendingPathComponent:@"config.json"];
    [[NSFileManager defaultManager] createDirectoryAtPath:_pluginsDir withIntermediateDirectories:YES attributes:nil error:nil];
    strlcpy(g_markerPath, [root stringByAppendingPathComponent:@"pending.txt"].fileSystemRepresentation, sizeof(g_markerPath));

    [self loadConfig];
    NSMutableDictionary *quarantine = _config[@"quarantine"];
    NSMutableArray<NSString *> *notes = [NSMutableArray array];

    /* 1. Lần trước chết giữa lúc làm việc với plugin nào? */
    NSString *marker = dx_marker_read();
    if (marker.length) {
        NSArray *parts = [marker componentsSeparatedByString:@"\t"];
        if (parts.count == 2 && [parts[0] length]) {
            quarantine[parts[0]] = parts[1];
            [notes addObject:[NSString stringWithFormat:@"%@ làm crash lần trước (bước: %@), đã cô lập.", parts[0], parts[1]]];
            DXLOGE("loader", "Cô lập %s do chết giữa bước %s", DXC(parts[0]), DXC(parts[1]));
        }
        dx_marker_clear();
    }

    /* 2. Liệt kê file plugin */
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_pluginsDir error:nil] ?: @[];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *f in all) {
        if ([f hasPrefix:@"."]) continue;
        if ([f.pathExtension.lowercaseString isEqualToString:@"dylib"]) [files addObject:f];
    }
    [files sortUsingSelector:@selector(compare:)];
    if (files.count > DX_MAX_PLUGINS) {
        [files removeObjectsInRange:NSMakeRange(DX_MAX_PLUGINS, files.count - DX_MAX_PLUGINS)];
        DXLOGW("loader", "Quá nhiều plugin, chỉ nạp %d cái đầu", DX_MAX_PLUGINS);
    }

    /* 3. Phân tích báo cáo crash lần trước */
    NSInteger streak = [_config[@"crashStreak"] integerValue];
    if (report.length) {
        streak++;
        _config[@"crashStreak"] = @(streak);
        for (NSString *f in files) {
            if ([report containsString:[NSString stringWithFormat:@" %@ +0x", f]]) {
                quarantine[f] = @"crash";
                [notes addObject:[NSString stringWithFormat:@"Crash lần trước có dấu vết trong %@, đã cô lập.", f]];
            }
        }
        if (streak >= 2) {
            _safeMode = YES;
            [notes addObject:@"Crash nhiều lần liên tiếp: chế độ an toàn, đã tạm tắt toàn bộ tweak. Bật lại từng cái để tìm thủ phạm."];
        }
    }
    _recoveryNote = notes.count ? [notes componentsJoinedByString:@"\n"] : nil;
    [self writeConfigSync:NO];

    /* Nếu chạy ổn định đủ lâu thì xoá bộ đếm crash */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DX_SAFE_SECONDS * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_config[@"crashStreak"] integerValue] != 0) {
            self->_config[@"crashStreak"] = @0;
            [self scheduleSave];
        }
    });

    DXLOGI("loader", "Có %lu plugin, chế độ an toàn: %s", (unsigned long)files.count, _safeMode ? "BẬT" : "tắt");
    [_pendingFiles setArray:files];
    _loading = _pendingFiles.count > 0;
    [self loadNextPending];
}

/* Nạp lần lượt, mỗi plugin một nhịp runloop để game không bị khựng */
- (void)loadNextPending {
    if (_pendingFiles.count == 0) {
        _loading = NO;
        [self postChange];
        return;
    }
    NSString *file = _pendingFiles.firstObject;
    [_pendingFiles removeObjectAtIndex:0];
    [self loadFileNamed:file];
    [self postChange];
    dispatch_async(dispatch_get_main_queue(), ^{ [self loadNextPending]; });
}

/* ---------------- Nạp 1 plugin ---------------- */

- (DXPlugin *)pluginForFile:(NSString *)file {
    for (DXPlugin *p in _plugins) if ([p.fileName isEqualToString:file]) return p;
    return nil;
}

- (void)failPlugin:(DXPlugin *)p message:(NSString *)msg {
    p.state = DXPluginStateFailed;
    p.errorMessage = msg;
    p.enabled = NO;
    DXLOGE("loader", "%s: %s", DXC(p.fileName), DXC(msg));
}

- (DXPlugin *)loadFileNamed:(NSString *)fileName {
    NSString *path = [_pluginsDir stringByAppendingPathComponent:fileName];
    DXPlugin *p = [[DXPlugin alloc] initWithFileName:fileName];
    [_plugins addObject:p];

    NSString *q = _config[@"quarantine"][fileName];
    if ([q isKindOfClass:[NSString class]]) {
        p.state = DXPluginStateQuarantined;
        p.errorMessage = [NSString stringWithFormat:@"Bị cô lập vì làm crash lần trước (bước: %@). Bấm \"Thử lại\" để nạp lại.", q];
        DXLOGW("loader", "%s đang bị cô lập, bỏ qua", DXC(fileName));
        return p;
    }
    if ([_retiredFiles containsObject:fileName]) {
        [self failPlugin:p message:@"File này vừa bị xoá, cần khởi động lại game để nạp bản mới."];
        return p;
    }

    unsigned long long size = 0;
    NSString *err = dx_check_macho(path, &size);
    p.fileSize = size;
    if (err) { [self failPlugin:p message:err]; return p; }

    dx_marker_set(fileName, "load");
    [self performLoad:p path:path];
    dx_marker_clear();
    return p;
}

- (NSString *)applyManifest:(const char *)json toPlugin:(DXPlugin *)p {
    if (!json) return @"dynex_manifest trả về NULL";
    const void *nul = memchr(json, 0, DX_MAX_MANIFEST_BYTES + 1);
    if (!nul) return @"Manifest quá dài hoặc không kết thúc chuỗi";
    NSData *data = [NSData dataWithBytes:json length:(NSUInteger)((const char *)nul - json)];

    NSError *je = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
    if (![root isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"Manifest không phải JSON hợp lệ (%@)", je.localizedDescription ?: @"?"];
    }
    NSDictionary *m = root;

    NSString *pid = m[@"id"], *name = m[@"name"];
    if (!dx_valid_id(pid)) return @"Manifest thiếu hoặc sai \"id\" (chỉ chữ, số, . _ -, tối đa 64 ký tự)";
    if (![name isKindOfClass:[NSString class]] || name.length == 0 || name.length > 64) return @"Manifest thiếu hoặc sai \"name\"";

    NSString *type = m[@"type"];
    BOOL own = [type isEqualToString:@"own"];
    if (type && !own && ![type isEqualToString:@"simple"]) return @"\"type\" chỉ nhận simple hoặc own";

    for (DXPlugin *other in _plugins) {
        if (other != p && other.state == DXPluginStateLoaded && [other.pluginId isEqualToString:pid]) {
            return [NSString stringWithFormat:@"Trùng id \"%@\" với %@", pid, other.fileName];
        }
    }
    if ([_retiredIds containsObject:pid]) return @"Plugin cùng id vừa bị xoá, cần khởi động lại game";

    NSArray *controls = @[];
    if (!own) {
        NSString *cerr = nil;
        controls = dx_sanitize_controls(m[@"controls"], &cerr);
        if (!controls) return cerr ?: @"Controls không hợp lệ";
    }

    NSString *ver = m[@"version"];
    p.pluginId = pid;
    p.name = name;
    p.version = ([ver isKindOfClass:[NSString class]] && ver.length <= 24) ? ver : @"";
    p.ownUI = own;
    p.controls = controls;
    if (own) {
        NSString *b = m[@"bubble"];
        if (![b isKindOfClass:[NSString class]] || b.length == 0) {
            b = [[name substringToIndex:MIN((NSUInteger)2, name.length)] uppercaseString];
        }
        NSRange r = [b rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN((NSUInteger)3, b.length))];
        p.bubbleText = [b substringWithRange:r];
        double h = dx_is_number(m[@"hue"]) ? [m[@"hue"] doubleValue] : 260;
        p.hue = fmin(fmax(h, 0), 360);
    }
    return nil;
}

- (void)performLoad:(DXPlugin *)p path:(NSString *)path {
    NSString *file = p.fileName;
    const char *cfile = file.UTF8String;

    /* dlopen: constructor của plugin chạy ngay ở đây */
    DXBreadcrumbBegin(cfile, "dlopen");
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    NSString *rawErr = nil;
    if (!h) {
        const char *de = dlerror();
        rawErr = de ? [NSString stringWithUTF8String:de] : @"dlopen thất bại (không rõ lý do)";
    }
    DXBreadcrumbEnd();
    if (!h) {
        NSString *hint = dx_dlopen_hint(rawErr ?: @"");
        [self failPlugin:p message:hint ? [NSString stringWithFormat:@"%@\n%@", hint, rawErr] : rawErr];
        return;
    }
    p.handle = h;
    DXLogEnsureHandlers();   /* lỡ plugin ghi đè bộ bắt crash */

    DXInitFn       fnInit     = (DXInitFn)dlsym(h, "dynex_init");
    DXManifestFn   fnManifest = (DXManifestFn)dlsym(h, "dynex_manifest");
    DXSetEnabledFn fnEnable   = (DXSetEnabledFn)dlsym(h, "dynex_set_enabled");
    if (!fnManifest || !fnEnable) {
        [self failPlugin:p message:@"Không phải plugin DYNEX: thiếu dynex_manifest hoặc dynex_set_enabled. (Dylib này đã vào bộ nhớ nhưng DYNEX không quản lý được.)"];
        return;
    }
    p.fnSetEnabled = fnEnable;
    p.fnSetOption  = (DXSetOptionFn)dlsym(h, "dynex_set_option");
    p.fnAction     = (DXActionFn)dlsym(h, "dynex_action");
    p.fnOpenUI     = (DXOpenUIFn)dlsym(h, "dynex_open_ui");

    Dl_info info;
    if (dladdr((const void *)fnManifest, &info) && info.dli_fbase) {
        DXLogRegisterImage(cfile, info.dli_fbase);
    }

    NSString *gerr = nil;
    if (fnInit) {
        DXBreadcrumbBegin(cfile, "init");
        gerr = dx_guard(^{ fnInit(&kHost); });
        DXBreadcrumbEnd();
        if (gerr) { [self failPlugin:p message:[@"dynex_init lỗi: " stringByAppendingString:gerr]]; return; }
    }

    __block const char *json = NULL;
    DXBreadcrumbBegin(cfile, "manifest");
    gerr = dx_guard(^{ json = fnManifest(); });
    DXBreadcrumbEnd();
    if (gerr) { [self failPlugin:p message:[@"dynex_manifest lỗi: " stringByAppendingString:gerr]]; return; }

    NSString *merr = [self applyManifest:json toPlugin:p];
    if (merr) { [self failPlugin:p message:merr]; return; }

    /* Khôi phục tuỳ chọn đã lưu */
    NSMutableDictionary *pc = [self configForId:p.pluginId];
    NSDictionary *saved = [pc[@"options"] isKindOfClass:[NSDictionary class]] ? pc[@"options"] : @{};
    for (NSDictionary *c in p.controls) {
        NSString *kind = c[@"kind"];
        if ([kind isEqualToString:@"button"]) continue;
        double v = [c[@"value"] doubleValue];
        id sv = saved[c[@"id"]];
        if (dx_is_number(sv)) v = [sv doubleValue];
        p.options[c[@"id"]] = @(dx_clamp_option(c, v));
    }
    if (p.fnSetOption) {
        DXSetOptionFn fnOpt = p.fnSetOption;
        DXBreadcrumbBegin(cfile, "restore");
        for (NSDictionary *c in p.controls) {
            if ([c[@"kind"] isEqualToString:@"button"]) continue;
            NSString *oid = c[@"id"];
            double v = p.options[oid].doubleValue;
            gerr = dx_guard(^{ fnOpt(oid.UTF8String, v); });
            if (gerr) break;
        }
        DXBreadcrumbEnd();
        if (gerr) { [self failPlugin:p message:[@"dynex_set_option lỗi: " stringByAppendingString:gerr]]; return; }
    }

    BOOL savedEnabled = [pc[@"enabled"] boolValue];
    BOOL en = savedEnabled && !_safeMode;
    if (savedEnabled && _safeMode) { pc[@"enabled"] = @NO; [self scheduleSave]; }

    DXBreadcrumbBegin(cfile, en ? "set_enabled(1)" : "set_enabled(0)");
    gerr = dx_guard(^{ fnEnable(en); });
    DXBreadcrumbEnd();
    if (gerr) { [self failPlugin:p message:[@"dynex_set_enabled lỗi: " stringByAppendingString:gerr]]; return; }

    p.enabled = en;
    p.state = DXPluginStateLoaded;
    p.errorMessage = nil;
    DXLOGI("loader", "Đã nạp %s (%s) id=%s %s", cfile, DXC(p.name), DXC(p.pluginId), en ? "[BẬT]" : "[ngủ đông]");
}

/* ---------------- Thao tác của người dùng ---------------- */

- (BOOL)setEnabled:(BOOL)enabled forPlugin:(DXPlugin *)p {
    if (![self requireMain:"setEnabled"] || p.state != DXPluginStateLoaded || !p.fnSetEnabled) return NO;
    if (p.enabled == enabled) return YES;

    DXSetEnabledFn fn = p.fnSetEnabled;
    const char *cfile = p.fileName.UTF8String;
    dx_marker_set(p.fileName, enabled ? "enable" : "disable");
    DXBreadcrumbBegin(cfile, enabled ? "set_enabled(1)" : "set_enabled(0)");
    NSString *gerr = dx_guard(^{ fn(enabled); });
    DXBreadcrumbEnd();
    dx_marker_clear();

    if (gerr) {
        DXLOGE("loader", "%s: set_enabled lỗi: %s", cfile, DXC(gerr));
        p.errorMessage = [@"Lỗi khi bật/tắt: " stringByAppendingString:gerr];
        [self postChange];
        return NO;
    }
    p.enabled = enabled;
    p.errorMessage = nil;
    [self configForId:p.pluginId][@"enabled"] = @(enabled);
    [self scheduleSave];
    DXLOGI("loader", "%s -> %s", cfile, enabled ? "BẬT" : "tắt");
    [self postChange];
    return YES;
}

- (NSDictionary *)controlWithId:(NSString *)cid forPlugin:(DXPlugin *)p {
    for (NSDictionary *c in p.controls) if ([c[@"id"] isEqualToString:cid]) return c;
    return nil;
}

- (void)setOption:(NSString *)optionId value:(double)value forPlugin:(DXPlugin *)p {
    if (![self requireMain:"setOption"] || p.state != DXPluginStateLoaded || !p.fnSetOption) return;
    NSDictionary *c = [self controlWithId:optionId forPlugin:p];
    if (!c || [c[@"kind"] isEqualToString:@"button"]) {
        DXLOGW("loader", "%s: tuỳ chọn không tồn tại: %s", DXC(p.fileName), DXC(optionId));
        return;
    }
    double v = dx_clamp_option(c, value);
    if (p.options[optionId] && p.options[optionId].doubleValue == v) return;
    p.options[optionId] = @(v);

    DXSetOptionFn fn = p.fnSetOption;
    DXBreadcrumbBegin(p.fileName.UTF8String, "set_option");
    NSString *gerr = dx_guard(^{ fn(optionId.UTF8String, v); });
    DXBreadcrumbEnd();
    if (gerr) DXLOGE("loader", "%s: set_option lỗi: %s", DXC(p.fileName), DXC(gerr));

    [self optionsConfigForId:p.pluginId][optionId] = @(v);
    [self scheduleSave];
}

- (void)performAction:(NSString *)actionId forPlugin:(DXPlugin *)p {
    if (![self requireMain:"performAction"] || p.state != DXPluginStateLoaded || !p.fnAction) return;
    NSDictionary *c = [self controlWithId:actionId forPlugin:p];
    if (!c || ![c[@"kind"] isEqualToString:@"button"]) {
        DXLOGW("loader", "%s: nút không tồn tại: %s", DXC(p.fileName), DXC(actionId));
        return;
    }
    DXActionFn fn = p.fnAction;
    dx_marker_set(p.fileName, "action");
    DXBreadcrumbBegin(p.fileName.UTF8String, "action");
    NSString *gerr = dx_guard(^{ fn(actionId.UTF8String); });
    DXBreadcrumbEnd();
    dx_marker_clear();
    if (gerr) DXLOGE("loader", "%s: action %s lỗi: %s", DXC(p.fileName), DXC(actionId), DXC(gerr));
    else DXLOGI("loader", "%s: action %s", DXC(p.fileName), DXC(actionId));
}

- (void)openUIForPlugin:(DXPlugin *)p {
    if (![self requireMain:"openUI"] || p.state != DXPluginStateLoaded || !p.ownUI || !p.enabled || !p.fnOpenUI) return;
    DXOpenUIFn fn = p.fnOpenUI;
    dx_marker_set(p.fileName, "open_ui");
    DXBreadcrumbBegin(p.fileName.UTF8String, "open_ui");
    NSString *gerr = dx_guard(^{ fn(); });
    DXBreadcrumbEnd();
    dx_marker_clear();
    if (gerr) DXLOGE("loader", "%s: open_ui lỗi: %s", DXC(p.fileName), DXC(gerr));
}

/* ---------------- Cô lập, xoá, nhập file ---------------- */

- (void)releaseQuarantineForPlugin:(DXPlugin *)p {
    if (![self requireMain:"releaseQuarantine"] || p.state != DXPluginStateQuarantined) return;
    NSString *file = p.fileName;
    [_config[@"quarantine"] removeObjectForKey:file];
    [_plugins removeObject:p];
    [self scheduleSave];
    DXLOGI("loader", "Gỡ cô lập %s, thử nạp lại", DXC(file));
    [self loadFileNamed:file];
    [self postChange];
}

- (void)removePlugin:(DXPlugin *)p {
    if (![self requireMain:"removePlugin"] || ![_plugins containsObject:p]) return;
    if (p.state == DXPluginStateLoaded && p.enabled) [self setEnabled:NO forPlugin:p];

    NSString *file = p.fileName;
    [[NSFileManager defaultManager] removeItemAtPath:[_pluginsDir stringByAppendingPathComponent:file] error:nil];
    if (p.handle) {   /* đã dlopen: ảnh còn nằm trong RAM tới lần khởi động sau */
        [_retiredFiles addObject:file];
        if (p.state == DXPluginStateLoaded) [_retiredIds addObject:p.pluginId];
    }
    if (p.state == DXPluginStateLoaded) [_config[@"plugins"] removeObjectForKey:p.pluginId];
    [_config[@"quarantine"] removeObjectForKey:file];
    [_plugins removeObject:p];
    [self scheduleSave];
    DXLOGI("loader", "Đã xoá %s", DXC(file));
    [self postChange];
}

- (void)importFileAtURL:(NSURL *)url completion:(void (^)(NSString *))completion {
    if (![self requireMain:"import"]) { completion(@"Lỗi nội bộ (không phải main thread)"); return; }
    if (!_started) { completion(@"DYNEX chưa khởi động xong"); return; }

    NSString *clean = dx_clean_filename(url.lastPathComponent ?: @"");
    if (![clean.pathExtension.lowercaseString isEqualToString:@"dylib"] || clean.length < 7) {
        completion(@"Chỉ nhận file .dylib");
        return;
    }
    if ([_retiredFiles containsObject:clean]) { completion(@"File này vừa bị xoá, cần khởi động lại game rồi nhập lại."); return; }
    if ([self pluginForFile:clean]) { completion(@"Đã có file cùng tên. Hãy xoá bản cũ trước."); return; }
    if (_plugins.count >= DX_MAX_PLUGINS) { completion(@"Đã đạt số plugin tối đa"); return; }

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *dir = _pluginsDir;
    dispatch_async(_copyQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tmp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.part", clean]];
        NSString *dst = [dir stringByAppendingPathComponent:clean];
        NSString *err = nil;
        NSError *ferr = nil;

        [fm removeItemAtPath:tmp error:nil];
        if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&ferr]) {
            err = [NSString stringWithFormat:@"Không chép được file: %@", ferr.localizedDescription ?: @"?"];
        }
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (!err) err = dx_check_macho(tmp, NULL);
        if (!err && [fm fileExistsAtPath:dst]) err = @"Đã có file cùng tên";
        if (!err && ![fm moveItemAtPath:tmp toPath:dst error:&ferr]) {
            err = [NSString stringWithFormat:@"Không lưu được file: %@", ferr.localizedDescription ?: @"?"];
        }
        if (err) [fm removeItemAtPath:tmp error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) {
                DXLOGW("loader", "Nhập %s thất bại: %s", DXC(clean), DXC(err));
                completion(err);
                return;
            }
            DXPlugin *p = [self loadFileNamed:clean];
            [self postChange];
            completion(p.state == DXPluginStateLoaded ? nil : (p.errorMessage ?: @"Nạp thất bại"));
        });
    });
}

@end
