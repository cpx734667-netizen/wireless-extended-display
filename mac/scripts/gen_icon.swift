// 生成 App 图标：深蓝渐变圆角方块 + 显示器/信号波纹
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 背景圆角
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let path = CGPath(roundedRect: rect, cornerWidth: 220, cornerHeight: 220, transform: nil)
ctx.addPath(path)
ctx.clip()

// 渐变
let colors = [
    CGColor(red: 0.15, green: 0.45, blue: 1.0, alpha: 1),
    CGColor(red: 0.04, green: 0.16, blue: 0.55, alpha: 1)
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// 显示器主体
let screenW: CGFloat = 560
let screenH: CGFloat = 360
let screenX = (size - screenW) / 2
let screenY = (size - screenH) / 2 + 40

// 屏幕边框（白）
let borderW: CGFloat = 26
let screenRect = CGRect(x: screenX, y: screenY, width: screenW, height: screenH)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let borderPath = CGPath(roundedRect: screenRect, cornerWidth: 44, cornerHeight: 44, transform: nil)
ctx.addPath(borderPath)
ctx.fillPath()

// 屏幕内部（深色）
let innerRect = screenRect.insetBy(dx: borderW, dy: borderW)
let innerPath = CGPath(roundedRect: innerRect, cornerWidth: 30, cornerHeight: 30, transform: nil)
ctx.addPath(innerPath)
ctx.setFillColor(CGColor(red: 0.05, green: 0.10, blue: 0.25, alpha: 1))
ctx.fillPath()

// 屏幕内容：信号波纹（左上角）
ctx.setStrokeColor(CGColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1))
ctx.setLineWidth(26)
ctx.setLineCap(.round)
let base = CGPoint(x: innerRect.minX + 110, y: innerRect.minY + 90)
for r in [60, 130, 200] as [CGFloat] {
    let arcPath = CGMutablePath()
    arcPath.addArc(center: base, radius: r, startAngle: -.pi * 0.72, endAngle: -.pi * 0.28, clockwise: false)
    ctx.addPath(arcPath)
    ctx.strokePath()
}

// 显示器底座
let standW: CGFloat = 26
let standH: CGFloat = 90
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: size / 2 - standW / 2, y: screenY - standH, width: standW, height: standH))
let footW: CGFloat = 220
let footPath = CGPath(roundedRect: CGRect(x: size / 2 - footW / 2, y: screenY - standH - 30, width: footW, height: 34),
                      cornerWidth: 17, cornerHeight: 17, transform: nil)
ctx.addPath(footPath)
ctx.fillPath()

let img = ctx.makeImage()!

// 输出 PNG
let rep = NSBitmapImageRep(cgImage: img)
if let data = rep.representation(using: .png, properties: [:]) {
    try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("icon written")
}
