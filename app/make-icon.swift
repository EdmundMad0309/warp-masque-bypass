// 生成 1024x1024 的 app 图标 PNG
import Cocoa
let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.98, green: 0.64, blue: 0.20, alpha: 1),
           ending:   NSColor(red: 0.95, green: 0.35, blue: 0.10, alpha: 1))!.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold)
if let sym = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let r = NSRect(x: (1024 - sym.size.width) / 2, y: (1024 - sym.size.height) / 2, width: sym.size.width, height: sym.size.height)
    tinted.draw(in: r)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
