import CoreText
import Foundation
let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SF-Mono-Regular.otf") as CFURL
let descs = CTFontManagerCreateFontDescriptorsFromURL(url) as! [CTFontDescriptor]
let base = CTFontCreateWithFontDescriptor(descs[0], 13, nil)
print("base:", CTFontCopyPostScriptName(base))
var mg: CGGlyph = 0; var mc: [UniChar] = Array("M".utf16)
_ = CTFontGetGlyphsForCharacters(base, &mc, &mg, 1)
var madv = CGSize.zero
CTFontGetAdvancesForGlyphs(base, .horizontal, [mg], &madv, 1)
print("cell advance:", madv.width)
for s in ["♥", "♡", "❤", "❥", "•", "»"] {
    let chars = Array(s.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    let has = CTFontGetGlyphsForCharacters(base, chars, &glyphs, chars.count)
    let fb = CTFontCreateForString(base, s as CFString, CFRange(location: 0, length: chars.count))
    var g2 = [CGGlyph](repeating: 0, count: chars.count)
    _ = CTFontGetGlyphsForCharacters(fb, chars, &g2, chars.count)
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(fb, .horizontal, g2, &adv, 1)
    let bb = CTFontGetBoundingRectsForGlyphs(fb, .horizontal, g2, nil, 1)
    print(s, String(format: "U+%04X", s.unicodeScalars.first!.value), "inSFMono:", has, "fallback:", CTFontCopyPostScriptName(fb), String(format: "advance %.2f, ink x %.2f..%.2f", adv.width, bb.minX, bb.maxX))
}
