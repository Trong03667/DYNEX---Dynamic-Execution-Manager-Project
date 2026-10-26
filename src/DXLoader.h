#ifndef DXLOADER_H
#define DXLOADER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DXPluginState) {
    DXPluginStateLoaded = 0,     // đã nạp, dùng được
    DXPluginStateFailed,         // lỗi (xem errorMessage)
    DXPluginStateQuarantined     // bị cô lập vì làm crash lần trước, chưa nạp
};

/// Phát trên main thread mỗi khi danh sách hoặc trạng thái plugin thay đổi.
extern NSNotificationName const DXLoaderDidChangeNotification;

/// Một plugin (chỉ đọc). UI dùng để dựng giao diện.
@interface DXPlugin : NSObject
@property (nonatomic, readonly, copy) NSString *fileName;
@property (nonatomic, readonly, copy) NSString *pluginId;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *version;
/// YES: plugin có giao diện riêng (bubble riêng). NO: nút con trong bảng.
@property (nonatomic, readonly) BOOL ownUI;
@property (nonatomic, readonly, copy) NSString *bubbleText;
@property (nonatomic, readonly) double hue;
/// Đã kiểm tra sạch: mỗi phần tử có id, kind (toggle|slider|button), label; slider có min, max, step, value, unit.
@property (nonatomic, readonly, copy) NSArray<NSDictionary *> *controls;
@property (nonatomic, readonly) DXPluginState state;
@property (nonatomic, readonly, copy, nullable) NSString *errorMessage;
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) unsigned long long fileSize;
/// YES: dylib thường (không có dynex_manifest). DYNEX chỉ nạp/không nạp, không điều khiển được bên trong.
@property (nonatomic, readonly) BOOL external;
/// YES: dylib ngoài đã tắt nhưng vẫn nằm trong bộ nhớ, chỉ thôi chạy sau khi khởi động lại game.
@property (nonatomic, readonly) BOOL needsRestart;
- (double)valueForOption:(NSString *)optionId;
@end


/// Quản lý plugin. TẤT CẢ phương thức chỉ gọi trên main thread.
@interface DXLoader : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSArray<DXPlugin *> *plugins;
@property (nonatomic, readonly, copy) NSString *pluginsDirectory;
/// YES: lần trước crash liên tiếp, toàn bộ tweak bị tạm tắt.
@property (nonatomic, readonly) BOOL safeMode;
/// Ghi chú khôi phục sau sự cố (để UI hiện banner). nil nếu bình thường.
@property (nonatomic, readonly, copy, nullable) NSString *recoveryNote;
/// YES: vẫn còn plugin đang chờ nạp.
@property (nonatomic, readonly) BOOL loading;

/// Gọi 1 lần sau DXLogSetup. Truyền kết quả của DXLogTakePreviousSessionReport().
- (void)startWithPreviousSessionReport:(nullable NSString *)report;

/// Chép file .dylib vào thư mục quản lý rồi nạp. completion: nil nếu thành công, ngược lại là thông báo lỗi.
- (void)importFileAtURL:(NSURL *)url completion:(void (^)(NSString *_Nullable errorMessage))completion;

- (BOOL)setEnabled:(BOOL)enabled forPlugin:(DXPlugin *)plugin;
- (void)setOption:(NSString *)optionId value:(double)value forPlugin:(DXPlugin *)plugin;
- (void)performAction:(NSString *)actionId forPlugin:(DXPlugin *)plugin;
- (void)openUIForPlugin:(DXPlugin *)plugin;

/// Gỡ cô lập rồi thử nạp lại.
- (void)releaseQuarantineForPlugin:(DXPlugin *)plugin;

/// Tắt, xoá file, bỏ khỏi danh sách. Phần đã nạp trong RAM chỉ giải phóng khi khởi động lại game.
- (void)removePlugin:(DXPlugin *)plugin;

/// Ghi cấu hình ra đĩa ngay.
- (void)flushConfig;

@end

NS_ASSUME_NONNULL_END

#endif /* DXLOADER_H */
