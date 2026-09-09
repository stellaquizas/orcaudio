import AppKit

func bitmap(size: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func appIcon() -> NSBitmapImageRep {
    bitmap(size: 1024) {
        let box = NSBezierPath(roundedRect: NSRect(x:100,y:100,width:824,height:824), xRadius:180,yRadius:180)
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width:0,height:-6)
        NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill();box.fill();NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(white:0.02,alpha:1), NSColor(white:0.075,alpha:1), NSColor(white:0.21,alpha:1)])!.draw(in: box, angle:90)
        NSColor(white:0.55,alpha:0.38).setStroke();box.lineWidth=3;box.stroke()
        let inset = NSBezierPath(roundedRect: NSRect(x:105,y:105,width:814,height:814),xRadius:176,yRadius:176)
        NSColor(white:1,alpha:0.06).setStroke();inset.lineWidth=2;inset.stroke()
        // Original voice mark: a waveform with a small, abstract fluke underneath.
        for (i,h) in [126.0,236.0,350.0,274.0,168.0].enumerated() {
            let bar = NSBezierPath(roundedRect:NSRect(x:301+Double(i)*92,y:568-h/2,width:54,height:h),xRadius:27,yRadius:27)
            NSGradient(colors:[NSColor(white:0.55,alpha:1),NSColor(white:0.96,alpha:1),.white])!.draw(in:bar,angle:90)
        }
        let tail = NSBezierPath()
        tail.move(to:NSPoint(x:342,y:326))
        tail.curve(to:NSPoint(x:512,y:282),controlPoint1:NSPoint(x:411,y:353),controlPoint2:NSPoint(x:478,y:331))
        tail.curve(to:NSPoint(x:682,y:326),controlPoint1:NSPoint(x:546,y:331),controlPoint2:NSPoint(x:613,y:353))
        tail.curve(to:NSPoint(x:512,y:216),controlPoint1:NSPoint(x:648,y:260),controlPoint2:NSPoint(x:560,y:276))
        tail.curve(to:NSPoint(x:342,y:326),controlPoint1:NSPoint(x:464,y:276),controlPoint2:NSPoint(x:376,y:260))
        tail.close()
        NSGradient(starting:NSColor(white:0.38,alpha:1),ending:NSColor(white:0.8,alpha:1))!.draw(in:tail,angle:90)

    }
}
@main struct IconRenderer {
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let large=appIcon()
        try large.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("Assets/AppIcon.png"))
        let iconset=root.appendingPathComponent("build/AppIcon.iconset")
        try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
        let image=NSImage(size:NSSize(width:1024,height:1024));image.addRepresentation(large)
        for points in [16,32,128,256,512] {
            for scale in [1,2] {
                let n=points*scale
                let rep=bitmap(size:n) { image.draw(in:NSRect(x:0,y:0,width:n,height:n),from:.zero,operation:.copy,fraction:1) }
                let name="icon_\(points)x\(points)\(scale==2 ? "@2x" : "").png"
                try rep.representation(using:.png,properties:[:])!.write(to:iconset.appendingPathComponent(name))
            }
        }
        // 30x18 pt template, exact Retina representation with no resampling at runtime.
        for scale in [1,2] {
            let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:30*scale,pixelsHigh:18*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            let ctx=NSGraphicsContext.current!.cgContext;ctx.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
            NSColor.black.setFill()
            for (i,h) in [4.0,8.0,12.0,9.0,5.0].enumerated() {
                NSBezierPath(roundedRect:NSRect(x:5+Double(i)*4.2,y:11-h/2,width:2.4,height:h),xRadius:1.2,yRadius:1.2).fill()
            }
            let tail=NSBezierPath()
            tail.move(to:NSPoint(x:9,y:4));tail.curve(to:NSPoint(x:15,y:2),controlPoint1:NSPoint(x:12,y:5),controlPoint2:NSPoint(x:14,y:4))
            tail.curve(to:NSPoint(x:21,y:4),controlPoint1:NSPoint(x:16,y:4),controlPoint2:NSPoint(x:18,y:5))
            tail.curve(to:NSPoint(x:15,y:0.5),controlPoint1:NSPoint(x:20,y:1.5),controlPoint2:NSPoint(x:17,y:2.5))
            tail.curve(to:NSPoint(x:9,y:4),controlPoint1:NSPoint(x:13,y:2.5),controlPoint2:NSPoint(x:10,y:1.5));tail.close();tail.fill()
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("Assets/MenuBarTemplate\(scale==2 ? "@2x" : "").png"))
        }
    }
}
