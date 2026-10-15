# NegTrans

macOS 原生彩负反转 App（Swift + SwiftUI + Accelerate）。

密度空间反转管线：linear → density → 反转 → density → 矩阵 → 增益 → 曲线 → linear → sRGB。

打开图片时自动白平衡 + 自动 dmax，滑杆可手动微调，可导出 TIFF。

## 构建

推送到 GitHub 后 Actions 自动编译出 DMG（见 Artifacts）。
