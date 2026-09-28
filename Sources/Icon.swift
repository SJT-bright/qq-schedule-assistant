import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
let rect=NSRect(x:80,y:80,width:864,height:864)
let path=NSBezierPath(roundedRect:rect,xRadius:190,yRadius:190)
NSGradient(starting:NSColor(red:0.33,green:0.34,blue:0.91,alpha:1),ending:NSColor(red:0.14,green:0.16,blue:0.53,alpha:1))!.draw(in:path,angle:-65)
if let symbol=NSImage(systemSymbolName:"paperplane.fill",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:430,weight:.medium)) {
    let white=symbol.withSymbolConfiguration(.init(paletteColors:[.white]))!
    white.draw(in:NSRect(x:275,y:340,width:500,height:480))
}
NSColor.white.withAlphaComponent(0.18).setFill(); NSBezierPath(roundedRect:NSRect(x:216,y:204,width:592,height:83),xRadius:40,yRadius:40).fill()
for x in [290,450,610] { NSColor.white.setFill(); NSBezierPath(roundedRect:NSRect(x:x,y:232,width:110,height:25),xRadius:12,yRadius:12).fill() }
image.unlockFocus()
let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output))
