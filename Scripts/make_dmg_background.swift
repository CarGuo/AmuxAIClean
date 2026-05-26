#!/usr/bin/env swift
//
// scripts/make_dmg_background.swift
//
// 用 CoreGraphics 生成 DMG 挂载窗口的背景图：
//   - 1648×1000（即 824×500 @2x，正好匹配 make_dmg.sh 设置的 Finder 窗口尺寸）
//   - 浅色对角渐变（cyan → lavender），Apple HIG 风格的安装器氛围
//   - 中央一条向右的虚线箭头（点状），暗示"把 .app 拖到 Applications"的方向
//   - 左右两个柔和 squircle 占位框（仅作为视觉层次，真实图标由 Finder 摆放在 (240,230)/(580,230)）
//
// 用法：
//   swift Scripts/make_dmg_background.swift docs/assets/dmg-background.png
//
// 设计参数：
//   坐标系采用 @1x 设计稿（824×500），渲染时 scale=2 直接出 @2x。
//   icon-size=128，AppleScript 里 .app 在 (240, 230)，Applications 在 (580, 230)；
//   箭头从 ~340 画到 ~480，避开两侧图标。

import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outPath: String = CommandLine.arguments.count >= 2
    ? CommandLine.arguments[1]
    : "docs/assets/dmg-background.png"

// ---- 输出尺寸 ----
let designW: CGFloat = 824
let designH: CGFloat = 500
let scale: CGFloat = 2  // @2x 给 Retina

let pixelW = Int(designW * scale)
let pixelH = Int(designH * scale)

// ---- 颜色 ----
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255.0, green: CGFloat(g)/255.0, blue: CGFloat(b)/255.0, alpha: a)
}

let bgTopLeft  = rgb(0xE8, 0xF4, 0xFC) // 浅 cyan
let bgBotRight = rgb(0xF1, 0xEB, 0xFC) // 浅 lavender
let arrowColor = rgb(0x60, 0xA5, 0xFA, 0.85) // muted blue
let placeholderStroke = rgb(0x94, 0xA3, 0xB8, 0.35) // slate-400 alpha
let placeholderFill   = rgb(0xFF, 0xFF, 0xFF, 0.55)

// ---- CG context ----
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: pixelW,
    height: pixelH,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("ERR: 无法创建 CGContext\n".data(using: .utf8)!)
    exit(1)
}

// 缩放到设计稿坐标（之后所有绘制按 824×500 的坐标系来写）
ctx.scaleBy(x: scale, y: scale)

// CoreGraphics 默认 origin 在左下角，我们设计上习惯左上角；不翻转也能画，
// 但 Y 方向镜像方便阅读 —— 这里保持 CG 原始坐标（左下角原点），数值要相应取 y 反向。
// 简化：直接以 CG 原生坐标写，注意 y 越大越靠上。

// ---- 1. 渐变背景 ----
let gradientColors = [bgTopLeft, bgBotRight] as CFArray
let gradientLocations: [CGFloat] = [0.0, 1.0]
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: gradientLocations) {
    // 左上 → 右下 的对角渐变（CG 坐标里左上 = (0, designH)，右下 = (designW, 0)）
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: designH),
        end:   CGPoint(x: designW, y: 0),
        options: []
    )
}

// ---- 2. 左右两个柔和 squircle 占位框 ----
//
// AppleScript 把 .app 放在 (240, 230)，Applications 放在 (580, 230)。
// AppleScript 的坐标系是窗口左上角 (0, 0)，y 向下；CG 坐标系 y 向上。
// 我们的设计稿 824×500，所以 CG_y = 500 - apple_y - icon_size/2 …… 这里直接画在视觉中央偏上的位置。
//
// 视觉策略：占位框比图标稍大（比如 168×168），让真实图标"落在"框中央，形成层次感。
let placeholderSize: CGFloat = 168
let cornerRadius: CGFloat = 38 // ~22% squircle 视感

func drawSoftSquircle(centerXDesign: CGFloat, centerYAppleScript: CGFloat) {
    // 把 AppleScript 的 (x, y_top-down) 转为 CG 的 (x, y_bottom-up)
    let cgY = designH - centerYAppleScript
    let rect = CGRect(
        x: centerXDesign - placeholderSize/2,
        y: cgY - placeholderSize/2,
        width: placeholderSize,
        height: placeholderSize
    )
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // 阴影：让框看起来像被轻轻嵌入
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14,
                  color: rgb(0x1F, 0x2A, 0x44, 0.10))
    ctx.setFillColor(placeholderFill)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // 描边
    ctx.setStrokeColor(placeholderStroke)
    ctx.setLineWidth(1.5)
    ctx.addPath(path)
    ctx.strokePath()
}

drawSoftSquircle(centerXDesign: 240, centerYAppleScript: 230)
drawSoftSquircle(centerXDesign: 580, centerYAppleScript: 230)

// ---- 3. 中央点状向右箭头 ----
//
// 从 x=345 画到 x=475，y 沿 AppleScript 230 那条线（CG_y = 500 - 230 = 270）。
// 用一串等距小圆点 + 末端三角箭头。
let arrowYAppleScript: CGFloat = 230
let arrowYCG: CGFloat = designH - arrowYAppleScript
let arrowStartX: CGFloat = 345
let arrowEndX:   CGFloat = 472
let dotRadius:   CGFloat = 3.2
let dotSpacing:  CGFloat = 14
let arrowHeadW:  CGFloat = 18
let arrowHeadH:  CGFloat = 22

ctx.setFillColor(arrowColor)

var x = arrowStartX
while x <= arrowEndX - arrowHeadW - 2 {
    let dot = CGRect(x: x - dotRadius, y: arrowYCG - dotRadius,
                     width: dotRadius * 2, height: dotRadius * 2)
    ctx.fillEllipse(in: dot)
    x += dotSpacing
}

// 箭头尖端（实心三角）
let headBaseX = arrowEndX - arrowHeadW
let headTop    = CGPoint(x: headBaseX,         y: arrowYCG + arrowHeadH/2)
let headBottom = CGPoint(x: headBaseX,         y: arrowYCG - arrowHeadH/2)
let headTip    = CGPoint(x: arrowEndX,         y: arrowYCG)
ctx.beginPath()
ctx.move(to: headTop)
ctx.addLine(to: headTip)
ctx.addLine(to: headBottom)
ctx.closePath()
ctx.fillPath()

// ---- 4. 输出 PNG ----
guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("ERR: makeImage 失败\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("ERR: 无法创建 ImageDestination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("ERR: 写入 PNG 失败\n".data(using: .utf8)!)
    exit(1)
}

print("[dmg-bg] 输出: \(outPath)  (\(pixelW)×\(pixelH) PNG @\(Int(scale))x)")
