#!/usr/bin/env swift
//
// scripts/make_app_icon.swift
//
// 用 CoreGraphics 把任意 1024×1024 源图变成"squircle 背景 + 居中 logo + 圆角"的
// 1024×1024 母版。
//
// 用法：
//   swift make_app_icon.swift <src.png> <out.png> <#rrggbb> <padding=0.12>
//
// Apple HIG（macOS Big Sur+）：
//   - AppIcon 边长 1024
//   - "logo 安全区"约占 824×824，四周留白 ≈ (1024-824)/2 = 100px ≈ 9.77%
//   - 圆角约为边长的 22.37%（squircle 实际是连续曲线，但 22.37% rounded rect 视觉非常接近）
//
// 这里 padding 默认 0.12（更保守一点，让小尺寸里 logo 不会贴边），可通过参数覆盖。

import Foundation
import AppKit
import CoreGraphics

guard CommandLine.arguments.count >= 4 else {
    FileHandle.standardError.write("usage: make_app_icon.swift <src.png> <out.png> <#rrggbb> [padding=0.12]\n".data(using: .utf8)!)
    exit(2)
}
let srcPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let bgHex = CommandLine.arguments[3]
let padding = CommandLine.arguments.count >= 5 ? (Double(CommandLine.arguments[4]) ?? 0.12) : 0.12

func parseHex(_ s: String) -> CGColor {
    var hex = s
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
        return CGColor(red: 0.05, green: 0.65, blue: 0.91, alpha: 1) // 默认亮蓝
    }
    let r = CGFloat((v >> 16) & 0xFF) / 255.0
    let g = CGFloat((v >> 8) & 0xFF) / 255.0
    let b = CGFloat(v & 0xFF) / 255.0
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

guard let srcImage = NSImage(contentsOfFile: srcPath),
      let cgSrcRaw = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("ERR: cannot load source: \(srcPath)\n".data(using: .utf8)!)
    exit(1)
}

/// 裁掉源图四周的透明像素（alpha < 阈值），返回紧凑 cropped CGImage。
/// 修复"原图本身留了一大圈透明 padding 导致最终 logo 看着小"。
func trimAlpha(_ img: CGImage, alphaThreshold: UInt8 = 8) -> CGImage {
    let w = img.width
    let h = img.height
    let bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let probe = CGContext(
        data: &pixels,
        width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return img }
    probe.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            let alpha = pixels[(y * w + x) * 4 + 3]
            if alpha > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return img }
    let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return img.cropping(to: cropRect) ?? img
}

let cgSrc = trimAlpha(cgSrcRaw)
print("[make_app_icon] trim: \(cgSrcRaw.width)x\(cgSrcRaw.height) -> \(cgSrc.width)x\(cgSrc.height)")

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("ERR: cannot create context\n".data(using: .utf8)!)
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// 1) 整张透明 → 画 squircle 背景（22.37% 圆角，很接近 macOS 默认 squircle）
let cornerRadius = CGFloat(size) * 0.2237
let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(bgPath)
ctx.setFillColor(parseHex(bgHex))
ctx.fillPath()

// 2) 在 squircle 背景上居中绘制源 logo，按 padding 留白；保持长宽比，等比缩放到方形 inner 区
let inset = CGFloat(size) * CGFloat(padding)
let innerSide = CGFloat(size) - inset * 2
let srcW = CGFloat(cgSrc.width)
let srcH = CGFloat(cgSrc.height)
let scale = min(innerSide / srcW, innerSide / srcH)
let drawW = srcW * scale
let drawH = srcH * scale
let drawX = (CGFloat(size) - drawW) / 2
let drawY = (CGFloat(size) - drawH) / 2

// 用 squircle 当裁切区域：logo 不会画到圆角外面
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(cgSrc, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
ctx.restoreGState()

guard let cgOut = ctx.makeImage() else {
    FileHandle.standardError.write("ERR: cannot makeImage\n".data(using: .utf8)!)
    exit(1)
}

let nsOut = NSBitmapImageRep(cgImage: cgOut)
guard let png = nsOut.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("ERR: cannot encode PNG\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("[make_app_icon] wrote \(outPath) (\(size)x\(size), bg=\(bgHex), padding=\(padding))")
} catch {
    FileHandle.standardError.write("ERR: write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
