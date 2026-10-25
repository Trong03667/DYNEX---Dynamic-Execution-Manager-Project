#ifndef DXLOG_H
#define DXLOG_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, DXLogLevel) {
    DXLogLevelDebug = 0,
    DXLogLevelInfo  = 1,
    DXLogLevelWarn  = 2,
    DXLogLevelError = 3
};

#ifdef __cplusplus
extern "C" {
#endif

/// Gọi 1 lần, càng sớm càng tốt, trên main thread. Tạo thư mục, mở log, cài bộ bắt crash.
void DXLogSetup(void);

/// Cài lại bộ bắt crash nếu plugin nào đó đã ghi đè. Gọi sau mỗi lần dlopen.
void DXLogEnsureHandlers(void);

/// Ghi 1 dòng log. Thread-safe, không cấp phát heap. Đừng gọi trong vòng lặp mỗi khung hình.
void DXLogWrite(DXLogLevel level, const char *tag, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

void DXLogSetMinLevel(DXLogLevel level);

/// Đăng ký 1 image (dylib) để báo cáo crash đổi địa chỉ thành "tên + offset".
/// header: con trỏ mach_header của image (lấy từ dladdr -> dli_fbase).
void DXLogRegisterImage(const char *name, const void *header);

/// Đánh dấu "đang làm bước này" ngay trước khi gọi vào plugin, và xoá dấu khi xong.
/// Nếu tiến trình chết giữa chừng (kể cả bị hệ thống kill), lần mở sau biết chết ở đâu.
void DXBreadcrumbBegin(const char *plugin, const char *step);
void DXBreadcrumbEnd(void);

/// Báo cáo về lần chạy trước (crash hoặc kết thúc bất thường). Mỗi sự kiện chỉ trả về 1 lần. Không có thì nil.
NSString *_Nullable DXLogTakePreviousSessionReport(void);

/// Đọc phần cuối của log (tối đa maxBytes) để hiện trong UI.
NSString *DXLogReadTail(NSUInteger maxBytes);

/// Xoá log và các báo cáo crash.
void DXLogClear(void);

/// Thư mục gốc DYNEX trong Documents của app.
NSString *DXLogRootDirectory(void);

#ifdef __cplusplus
}
#endif

#define DXLOGD(tag, ...) DXLogWrite(DXLogLevelDebug, (tag), __VA_ARGS__)
#define DXLOGI(tag, ...) DXLogWrite(DXLogLevelInfo,  (tag), __VA_ARGS__)
#define DXLOGW(tag, ...) DXLogWrite(DXLogLevelWarn,  (tag), __VA_ARGS__)
#define DXLOGE(tag, ...) DXLogWrite(DXLogLevelError, (tag), __VA_ARGS__)

NS_ASSUME_NONNULL_END

#endif /* DXLOG_H */
