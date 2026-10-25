/*
 * dynex.h - Hợp đồng giữa DYNEX Core và plugin (.dylib)
 *
 * Plugin export các hàm C dưới đây. Loader tìm bằng dlsym, hàm nào không có thì bỏ qua
 * (trừ 2 hàm bắt buộc: dynex_manifest, dynex_set_enabled).
 *
 * THỨ TỰ GỌI (luôn trên main thread):
 *   dlopen -> dynex_init -> dynex_manifest -> dynex_set_option (từng tuỳ chọn đã lưu)
 *          -> dynex_set_enabled(đã lưu)
 *   Sau đó: dynex_set_enabled / dynex_set_option / dynex_action / dynex_open_ui theo thao tác của người dùng.
 *
 * QUY TẮC VÀNG CHO PLUGIN:
 *   - Constructor (__attribute__((constructor))) chạy ngay lúc dlopen: KHÔNG được hook trong đó.
 *   - Cài hook MỘT LẦN (trong dynex_init hoặc lần bật đầu), hàm thay thế tự kiểm tra cờ enabled:
 *     tắt thì gọi thẳng hàm gốc. Không gỡ hook khi tắt.
 *   - Các hàm dynex_* phải trả về nhanh, không chặn main thread.
 *
 * MANIFEST (chuỗi JSON UTF-8, tĩnh, không giải phóng):
 *   {
 *     "id": "com.example.speed",          // bắt buộc, [A-Za-z0-9._-], tối đa 64 ký tự
 *     "name": "SpeedHack",                // bắt buộc
 *     "version": "1.0",
 *     "type": "simple",                   // "simple": nút con trong bảng | "own": bubble riêng
 *     "bubble": "SP", "hue": 150,         // chỉ dùng khi type = "own"
 *     "controls": [                       // chỉ dùng khi type = "simple"
 *       {"id":"mul","kind":"slider","label":"Tốc độ","min":0.5,"max":5,"step":0.5,"value":1,"unit":"x"},
 *       {"id":"rev","kind":"toggle","label":"Chạy ngược","value":false},
 *       {"id":"reset","kind":"button","label":"Reset"}
 *     ]
 *   }
 *   Toggle truyền vào dynex_set_option dưới dạng 0.0 hoặc 1.0.
 */
#ifndef DYNEX_H
#define DYNEX_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DYNEX_API_VERSION 1
#define DYNEX_EXPORT __attribute__((visibility("default"), used))

typedef enum {
    DYNEX_LOG_DEBUG = 0,
    DYNEX_LOG_INFO  = 1,
    DYNEX_LOG_WARN  = 2,
    DYNEX_LOG_ERROR = 3
} DynexLogLevel;

/* Core đưa cho plugin trong dynex_init. Con trỏ hợp lệ suốt vòng đời tiến trình. */
typedef struct DynexHost {
    uint32_t api_version;
    void (*log)(DynexLogLevel level, const char *plugin_id, const char *message);
} DynexHost;

/* ---- Plugin export ---- */

/* [Tuỳ chọn] Gọi 1 lần ngay sau khi nạp. */
DYNEX_EXPORT void dynex_init(const DynexHost *host);

/* [Bắt buộc] Trả về JSON manifest. */
DYNEX_EXPORT const char *dynex_manifest(void);

/* [Bắt buộc] Bật/tắt tweak. Phải nhẹ và lặp lại an toàn (gọi nhiều lần cùng giá trị không sao). */
DYNEX_EXPORT void dynex_set_enabled(bool enabled);

/* [Tuỳ chọn] Người dùng đổi một tuỳ chọn. */
DYNEX_EXPORT void dynex_set_option(const char *option_id, double value);

/* [Tuỳ chọn] Người dùng bấm một nút. */
DYNEX_EXPORT void dynex_action(const char *action_id);

/* [Tuỳ chọn] Với type "own": người dùng bấm bubble riêng, plugin tự mở giao diện của nó. */
DYNEX_EXPORT void dynex_open_ui(void);

#ifdef __cplusplus
}
#endif

#endif /* DYNEX_H */
