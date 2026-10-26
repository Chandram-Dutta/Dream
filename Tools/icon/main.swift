import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws Dream's app icon: a page taking shape out of the Aura. The light blooms at the top in a
// surface's accent and companion colors, as it does behind every page while it's being made, and
// a page comes toward you out of it, still light at its far edge and paper at its near one.
//
// Run Tools/icon.sh to write the three appearances iOS asks for (any, dark and tinted) into
// Dream/Assets.xcassets/AppIcon.appiconset. Everything worth changing is in the parameters below.
// Lengths are fractions of the icon's side, with y running down.

// MARK: - Parameters

let side = 1024.0

/// iOS's system colors, as Dream's palette uses them (Dream/UI/Theme.swift, Server/src/palette.ts):
/// blue with its companion cyan, over indigo.
let blue = RGB(0x0088FF), cyan = RGB(0x00C0E8), indigo = RGB(0x6155F5)
let white = RGB(0xFFFFFF), black = RGB(0x000000)

/// The field: a ground that darkens downward, and the Aura's blooms over it, each as
/// (color, center x, center y, radius, strength).
struct Field {
    var top: RGB
    var bottom: RGB
    var blooms: [(RGB, Double, Double, Double, Double)]
}

let fields: [Appearance: Field] = [
    .any: Field(top: RGB(0x1B2A8A), bottom: RGB(0x0B0A2E), blooms: [
        (blue, 0.26, 0.06, 0.72, 1.0),
        (cyan, 0.84, 0.03, 0.62, 0.95),
        (indigo, 0.50, 0.36, 0.52, 0.7),
    ]),
    .dark: Field(top: RGB(0x04050E), bottom: RGB(0x04050E), blooms: [
        (blue, 0.26, 0.06, 0.70, 0.8),
        (cyan, 0.84, 0.03, 0.60, 0.7),
        (indigo, 0.50, 0.36, 0.50, 0.5),
    ]),
    .tinted: Field(top: black, bottom: black, blooms: [
        (white, 0.50, 0.02, 0.80, 0.30),
    ]),
]

/// The page, seen tipped back: its far edge (top) and near edge (bottom), and how round its corners are.
let page = (top: 0.30, bottom: 0.84, topWidth: 0.34, bottomWidth: 0.72, corner: 0.06)
/// Where the page is still light, from its far edge (0) to its near one (1): it starts out
/// `faint`, becomes solid between `solid`'s two points, and turns from the companion color to
/// paper between `paper`'s.
let fade = (faint: 0.32, solid: (0.0, 0.72), paper: (0.12, 0.66))
/// How bright the paper is in each appearance.
let paper: [Appearance: Double] = [.any: 1, .dark: 0.92, .tinted: 1]

// MARK: - Drawing

enum Appearance: CaseIterable {
    case any, dark, tinted

    var filename: String {
        switch self {
        case .any: "AppIcon.png"
        case .dark: "AppIcon-Dark.png"
        case .tinted: "AppIcon-Tinted.png"
        }
    }

    /// iOS tints the tinted icon itself, from a grayscale one.
    var isGray: Bool { self == .tinted }
}

struct RGB {
    let r: Double, g: Double, b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ rgb: RGB, _ alpha: Double = 1, gray: Bool) -> CGColor {
    guard gray else { return CGColor(colorSpace: space, components: [rgb.r, rgb.g, rgb.b, alpha])! }
    let level = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
    return CGColor(colorSpace: space, components: [level, level, level, alpha])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// A soft round bloom that melts into what's around it, like a point of the Aura's mesh gradient.
func bloom(_ context: CGContext, _ rgb: RGB, x: Double, y: Double, radius: Double, strength: Double, gray: Bool) {
    let steps = 24
    let stops = (0...steps).map { Double($0) / Double(steps) }
    let colors = stops.map { t in color(rgb, strength * (1 - t * t * (3 - 2 * t)), gray: gray) }
    let center = CGPoint(x: x * side, y: y * side)
    context.drawRadialGradient(gradient(colors, stops.map { CGFloat($0) }), startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius * side, options: [])
}

/// A polygon with every corner rounded by the same radius.
func rounded(_ points: [CGPoint], radius: Double) -> CGPath {
    let path = CGMutablePath()
    let last = points[points.count - 1], first = points[0]
    path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
    for index in points.indices {
        path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count], radius: radius)
    }
    path.closeSubpath()
    return path
}

func render(_ appearance: Appearance) -> CGImage {
    let gray = appearance.isGray
    let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    // The field.
    let field = fields[appearance]!
    context.drawLinearGradient(gradient([color(field.top, gray: gray), color(field.bottom, gray: gray)], [0, 1]),
                               start: .zero, end: CGPoint(x: 0, y: side), options: [])
    for (rgb, x, y, radius, strength) in field.blooms {
        bloom(context, rgb, x: x, y: y, radius: radius, strength: strength, gray: gray)
    }

    // The page, coming out of the light.
    let (top, bottom) = (page.top * side, page.bottom * side)
    let outline = rounded([
        CGPoint(x: (0.5 - page.topWidth / 2) * side, y: top),
        CGPoint(x: (0.5 + page.topWidth / 2) * side, y: top),
        CGPoint(x: (0.5 + page.bottomWidth / 2) * side, y: bottom),
        CGPoint(x: (0.5 - page.bottomWidth / 2) * side, y: bottom),
    ], radius: page.corner * side)
    let brightness = paper[appearance]!
    context.saveGState()
    context.addPath(outline)
    context.clip()
    func smooth(_ t: Double, _ range: (Double, Double)) -> Double {
        let x = min(max((t - range.0) / (range.1 - range.0), 0), 1)
        return x * x * (3 - 2 * x)
    }
    let stops = (0...32).map { Double($0) / 32 }
    let colors = stops.map { t in
        let mix = smooth(t, fade.paper)
        let rgb = RGB(r: cyan.r + (white.r - cyan.r) * mix, g: cyan.g + (white.g - cyan.g) * mix, b: cyan.b + (white.b - cyan.b) * mix)
        return color(rgb, (fade.faint + (1 - fade.faint) * smooth(t, fade.solid)) * brightness, gray: gray)
    }
    context.drawLinearGradient(gradient(colors, stops.map { CGFloat($0) }),
                               start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    context.restoreGState()
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

// MARK: - Main

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Dream/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for appearance in Appearance.allCases {
    write(render(appearance), to: folder.appending(path: appearance.filename))
}

// One 1024-point image per appearance; iOS makes every other size from it.
let contents = """
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-Dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "AppIcon-Tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(Appearance.allCases.count) icons to \(folder.path)")
