# JTV

Ứng dụng iOS xem phim & đọc truyện tranh theo cơ chế **plugin JavaScript**,
với nguồn plugin riêng của người dùng (không phụ thuộc kho của tác giả gốc).

- **Nguồn mặc định:** `https://raw.githubusercontent.com/zjoenguyenz/jtv-source/main/plugins.json`
  (có thể thêm / xoá nguồn ngay trong Cài đặt → Nguồn plugin)
- **Engine:** mỗi plugin là một script chạy trong JavaScriptCore với hợp đồng
  hàm thống nhất (`getManifest`, `getHomeSections`, `getUrlList`,
  `parseListResponse`, `getUrlDetail`, `parseMovieDetail`,
  `parseDetailResponse`, `parseEmbedResponse`, …).
- **Phát:** AVPlayer native (m3u8/mp4 kèm header tuỳ chỉnh), webview embed có
  bắt link m3u8 tự động chuyển sang player native, và trình đọc truyện dọc
  cho plugin truyện (type `MANGA`).
- **Thư viện:** Yêu thích + Đang xem tiếp (lưu tiến độ theo tập/chương).
- **Nội dung 18+:** mặc định ẩn, bật trong Cài đặt sau khi xác nhận.

## Build

Project dùng [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open JTV.xcodeproj
```

Trên GitHub: workflow **Build JTV IPA** (chỉ chạy tay qua `workflow_dispatch`)
build bản Release không ký số và đóng gói `JTV.ipa` làm artifact.

- Bundle ID: `com.luun.nguyen.jtv`
- iOS 17+, Swift 5.9, SwiftUI, không thư viện ngoài.
