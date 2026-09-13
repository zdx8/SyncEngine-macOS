// 生成应用图标。
//
// 为什么用代码画而不是放一张 PNG：
//   1. 不需要外部图形工具，也不把二进制资源塞进版本库
//   2. 图标与品牌色随代码一起演进，改一个常量即可重出全套尺寸
//
// 用法（由 Scripts/build_app.sh 调用）：
//   swiftc -O -o /tmp/make-icon Scripts/make_icon.swift
//   /tmp/make-icon <输出的 .iconset 目录>

import AppKit
import Foundation

/// 品牌色 `#32CD32`，与界面强调色（`Palette.accent`）保持一致。
///
/// 用 `50.0/255.0` 这样的写法而不是换算后的小数，是为了让"改哪个通道、
/// 改成什么值"在代码里一眼可见 —— 十六进制与浮点小数的对应关系靠心算是会出错的。
let brandRed: CGFloat = 0x32 / 255.0   // 50
let brandGreen: CGFloat = 0xCD / 255.0 // 205
let brandBlue: CGFloat = 0x32 / 255.0  // 50

let brandColor = NSColor(srgbRed: brandRed, green: brandGreen, blue: brandBlue, alpha: 1.0)

/// iconset 各尺寸与文件名的对应关系**不能错**，否则 iconutil 报错或图标模糊。
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let context = NSGraphicsContext.current?.cgContext else { return nil }

    let size = CGFloat(pixels)

    // 圆角底板（macOS 图标的标准圆角比例约为边长的 22.5%）
    let inset = size * 0.055
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    context.addPath(CGPath(roundedRect: body,
                           cornerWidth: size * 0.225,
                           cornerHeight: size * 0.225,
                           transform: nil))
    context.clip()

    // 底板填色。
    //
    // 用**纯色**而不是渐变：品牌色是一个明确的十六进制值，渐变会让它变成一段
    // 色域，"底色是 #32CD32"这句话就不再成立，也无从验证。
    // 想要一点立体感的话，可以改成 `brandColor` 到略深一档的渐变，
    // 代价是"图标底色恰好等于 #32CD32"这个断言不再成立。
    context.setFillColor(brandColor.cgColor)
    context.fill(body)

    // 中心图形：用 SF Symbol，再染成白色
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                            accessibilityDescription: nil),
       let configured = symbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)) {
        let symbolSize = configured.size
        let tinted = NSImage(size: symbolSize)
        tinted.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: symbolSize))
        NSColor.white.set()
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: NSRect(
            x: (size - symbolSize.width) / 2,
            y: (size - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        ))
    }

    return rep.representation(using: .png, properties: [:])
}

// ─────────────────────────────────────────────────────── 主流程 --

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("用法：make_icon <输出的 .iconset 目录>\n".data(using: .utf8)!)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    guard let data = renderIcon(pixels: variant.pixels) else {
        FileHandle.standardError.write("渲染失败：\(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(variant.name))
}

print("已生成 \(variants.count) 个尺寸 → \(outputDirectory.path)")
