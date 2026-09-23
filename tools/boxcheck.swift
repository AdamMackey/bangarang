import CoreText
import Foundation
let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SF-Mono-Regular.otf") as CFURL
let descs = CTFontManagerCreateFontDescriptorsFromURL(url) as! [CTFontDescriptor]
let f = CTFontCreateWithFontDescriptor(descs[0], 12, nil)
print(String(format: "ascent %.2f descent %.2f leading %.2f", CTFontGetAscent(f), CTFontGetDescent(f), CTFontGetLeading(f)))
for s in ["─", "│", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "━", "┃"] {
    let chars = Array(s.utf16)
    var g = [CGGlyph](repeating: 0, count: chars.count)
    let has = CTFontGetGlyphsForCharacters(f, chars, &g, chars.count)
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(f, .horizontal, g, &adv, 1)
    let bb = CTFontGetBoundingRectsForGlyphs(f, .horizontal, g, nil, 1)
    print(s, has ? "in SF Mono" : "MISSING", String(format: "advance %.2f  ink x %.2f..%.2f  y %.2f..%.2f", adv.width, bb.minX, bb.maxX, bb.minY, bb.maxY))
}
