import AppKit

// Reproducible vector artwork rendered to the single-size iOS app icon.
let size = 1024
guard
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else {
    fatalError("Cannot create icon render context")
}
context.setFillColor(CGColor(red: 0.10, green: 0.20, blue: 0.16, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setStrokeColor(CGColor(red: 0.96, green: 0.96, blue: 0.92, alpha: 0.22))
context.setLineWidth(5)
context.stroke(CGRect(x: 160, y: 140, width: 704, height: 744))
context.move(to: CGPoint(x: 160, y: 512))
context.addLine(to: CGPoint(x: 864, y: 512))
context.strokePath()
context.setFillColor(CGColor(red: 0.81, green: 0.93, blue: 0.37, alpha: 1))
context.fillEllipse(in: CGRect(x: 252, y: 252, width: 520, height: 520))
context.saveGState()
context.addEllipse(in: CGRect(x: 252, y: 252, width: 520, height: 520))
context.clip()
context.setStrokeColor(CGColor(red: 0.10, green: 0.20, blue: 0.16, alpha: 1))
context.setLineWidth(22)
context.addEllipse(in: CGRect(x: 30, y: 385, width: 410, height: 440))
context.strokePath()
context.addEllipse(in: CGRect(x: 590, y: 170, width: 410, height: 440))
context.strokePath()
context.restoreGState()
guard let image = context.makeImage(), CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Tools/RenderAppIcon.swift <output.png>")
}
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode icon")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
