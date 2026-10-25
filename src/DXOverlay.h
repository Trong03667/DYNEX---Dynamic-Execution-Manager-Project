#ifndef DXOVERLAY_H
#define DXOVERLAY_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Giao diện nổi của DYNEX: bubble logo, bảng quản lý, bubble riêng của từng tweak.
@interface DXOverlay : NSObject

+ (instancetype)shared;

/// Báo cáo sự cố lần chạy trước (nếu có), hiện trong tab Nhật ký.
@property (nonatomic, copy, nullable) NSString *previousReport;

/// Gọi 1 lần trên main thread, sau khi app đã active.
- (void)start;

@end

NS_ASSUME_NONNULL_END

#endif /* DXOVERLAY_H */
