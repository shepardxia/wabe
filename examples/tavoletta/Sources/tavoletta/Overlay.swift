
import CoreGraphics
import CoreText
import Foundation
import simd

// MARK: - Palette

private let sinopiaHex: UInt32 = 0xB0_3A_24  // fresco underdrawing red
private let carraraHex: UInt32 = 0xF2_ED_E0
private let inkHex: UInt32 = 0x3A_31_28
private let holeHex: UInt32 = 0x1E_18_11
private let glareHex: UInt32 = 0xFF_F4_D8  // sunlight off glass
private let deviceRGB = CGColorSpaceCreateDeviceRGB()

private func rgb(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha))
}

/// How square-on counts as square-on. Inside this, the peephole and the panel centre are declared
/// coincident and both marks change treatment — the demo's one moment of lock.
private let facingToleranceDeg = 0.75

private enum Face {
    static let mono = CTFontCreateWithName("Menlo-Regular" as CFString, 11, nil)
    static let label = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 9, nil)
    static let caption = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 10, nil)
}

// MARK: - Entry point

/// Draws the perspective construction into a bottom-left-origin, y-up context measuring `size`
/// points. Pure function of its arguments.
func drawConstruction(_ c: Construction, in ctx: CGContext, size: CGSize) {
    guard size.width > 1, size.height > 1 else { return }
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.textMatrix = .identity

    // Laid out first, drawn last: the labels need its rectangle to keep out from under it, and it
    // needs to sit on top of everything so the numbers stay readable.
    let readout = Readout(c, size: size)

    // Under everything: the glass catching the sun. Drawn first so the construction stays legible
    // on top of it, the way an underdrawing survives a glaze.
    drawGlare(c, ctx, size)

    if c.showLines {
        let locked = abs(c.offAxisDeg) < facingToleranceDeg
        drawRays(c, ctx, size)
        drawHorizon(c, ctx, size, avoid: readout.plate)
        drawVanishing(c, ctx, size, avoid: readout.plate)
        drawPanelCentre(ctx, size, locked: locked)
        drawPeephole(c, ctx, size, locked: locked, avoid: readout.plate)
    }
    readout.draw(ctx)
}

// MARK: - The sun on the glass

private func drawGlare(_ c: Construction, _ ctx: CGContext, _ size: CGSize) {
    ctx.saveGState()
    defer { ctx.restoreGState() }

    // Sky off the glass: weakest at the bottom of the picture, which shows the pavement, and
    // strongest at the top, which shows the sky itself.
    let veil = c.veiling * 0.16
    if veil > 0.003, let wash = CGGradient(colorsSpace: deviceRGB,
                                          colors: [rgb(glareHex, veil * 0.25),
                                                   rgb(glareHex, veil)] as CFArray,
                                          locations: [0, 1]) {
        ctx.drawLinearGradient(wash, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: size.height), options: [])
    }

    guard c.glintStrength > 0.02 else { return }
    let sheen = pow(c.glintStrength, 34) * 0.15
    if sheen > 0.004 {
        ctx.setFillColor(rgb(glareHex, sheen))
        ctx.fill(CGRect(origin: .zero, size: size))
    }

    guard let g = c.glint else { return }
    let p = viewPoint(g, size: size)
    let r = min(size.width, size.height) * 0.42
    let core = pow(c.glintStrength, 40)
    guard let bloom = CGGradient(colorsSpace: deviceRGB,
                                 colors: [rgb(glareHex, 0.60 * core + 0.05),
                                          rgb(glareHex, 0.20 * core + 0.02),
                                          rgb(glareHex, 0)] as CFArray,
                                 locations: [0, 0.30, 1])
    else { return }
    ctx.drawRadialGradient(bloom, startCenter: p, startRadius: 0, endCenter: p, endRadius: r,
                           options: [])

    // The hot centre, only once the pane is really pointed at it.
    if core > 0.02 {
        ctx.setFillColor(rgb(0xFF_FD_F2, min(0.80, core)))
        let hot = min(size.width, size.height) * 0.012
        ctx.fillEllipse(in: CGRect(x: p.x - hot, y: p.y - hot, width: hot * 2, height: hot * 2))
    }
}

// MARK: - The two families of pavement lines

private func drawRays(_ c: Construction, _ ctx: CGContext, _ size: CGSize) {
    ctx.setStrokeColor(rgb(sinopiaHex, 0.80))
    ctx.setLineWidth(1.7)
    strokeSegments(ctx, c.orthogonals, size)

    // Dashed, so where the two families cross the eye can still tell which is which.
    ctx.setStrokeColor(rgb(sinopiaHex, 0.62))
    ctx.setLineWidth(1.3)
    ctx.setLineDash(phase: 0, lengths: [5, 4])
    strokeSegments(ctx, c.transversals, size)
    ctx.setLineDash(phase: 0, lengths: [])
}

private func strokeSegments(_ ctx: CGContext, _ segs: [(SIMD2<Double>, SIMD2<Double>)], _ size: CGSize) {
    guard !segs.isEmpty else { return }
    ctx.beginPath()
    for (a, b) in segs {
        ctx.move(to: viewPoint(a, size: size))
        ctx.addLine(to: viewPoint(b, size: size))
    }
    ctx.strokePath()
}

// MARK: - Horizon

private func drawHorizon(_ c: Construction, _ ctx: CGContext, _ size: CGSize, avoid: CGRect) {
    guard let (a, b) = c.horizon else { return }
    let pa = viewPoint(a, size: size), pb = viewPoint(b, size: size)
    ctx.setStrokeColor(rgb(sinopiaHex, 0.85))
    ctx.setLineWidth(2)
    ctx.beginPath()
    ctx.move(to: pa)
    ctx.addLine(to: pb)
    ctx.strokePath()

    // Label the left-hand end, sitting above the line; the clamp in drawLabel keeps it on-panel
    // when the horizon runs out through a corner.
    let end = pa.x <= pb.x ? pa : pb
    drawLabel(ctx, "horizon", at: CGPoint(x: end.x + 8, y: end.y + 7), anchor: .left, in: size, avoid: avoid)
}

// MARK: - Vanishing point

private func drawVanishing(_ c: Construction, _ ctx: CGContext, _ size: CGSize, avoid: CGRect) {
    guard let v = c.vanishing else { return }

    if max(abs(v.x), abs(v.y)) <= 1.0 {
        let p = viewPoint(v, size: size)
        ctx.setStrokeColor(rgb(sinopiaHex, 0.9))
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        ctx.strokePath()
        cross(ctx, at: p, arm: 12, gap: 4)
        drawLabel(ctx, "vanishing point", at: CGPoint(x: p.x, y: p.y - 24), anchor: .center, in: size, avoid: avoid)
        return
    }

    guard let (_, edge) = clipToUnitSquare(SIMD2(0, 0), v) else { return }
    let tip = viewPoint(edge, size: size)
    let mid = viewPoint(SIMD2(0, 0), size: size)
    // Spelled out in CGFloat: mixing CGFloat and literals in one expression sends Swift's overload
    // resolution off a cliff here.
    let dx: CGFloat = tip.x - mid.x
    let dy: CGFloat = tip.y - mid.y
    let len: CGFloat = hypot(dx, dy)
    guard len > 1e-6 else { return }
    let ux: CGFloat = dx / len, uy: CGFloat = dy / len
    let nx: CGFloat = -uy, ny: CGFloat = ux
    let inset: CGFloat = 26
    var apex = CGPoint(x: tip.x - ux * 12, y: tip.y - uy * 12)
    apex.x = min(max(apex.x, inset), max(inset, size.width - inset))
    apex.y = min(max(apex.y, inset), max(inset, size.height - inset))
    if apex.x < avoid.maxX + 20 && apex.y < avoid.maxY + 20 { apex.y = avoid.maxY + 22 }
    let base = CGPoint(x: apex.x - ux * 12, y: apex.y - uy * 12)

    ctx.setFillColor(rgb(sinopiaHex, 0.85))
    ctx.beginPath()
    ctx.move(to: apex)
    ctx.addLine(to: CGPoint(x: base.x + nx * 5.5, y: base.y + ny * 5.5))
    ctx.addLine(to: CGPoint(x: base.x - nx * 5.5, y: base.y - ny * 5.5))
    ctx.closePath()
    ctx.fillPath()

    let high = apex.y > size.height / 2
    let anchorPoint = CGPoint(x: apex.x, y: apex.y + (high ? -20 : 20))
    drawLabel(ctx, "vanishing point", at: anchorPoint, anchor: .center, in: size, avoid: avoid)
}

// MARK: - Panel centre and peephole

/// The geometric centre of the screen. Only interesting in relation to the peephole: the two
/// coincide exactly when the panel faces the eye square on.
private func drawPanelCentre(_ ctx: CGContext, _ size: CGSize, locked: Bool) {
    let p = viewPoint(SIMD2(0, 0), size: size)
    ctx.setStrokeColor(rgb(sinopiaHex, locked ? 0.95 : 0.30))
    ctx.setLineWidth(locked ? 1.6 : 1.0)
    // When locked the arms have to clear both the peephole's 11.5 pt rim and its 15 pt halo, or the
    // registration — the whole point of the demo — disappears underneath the mark it registers on.
    cross(ctx, at: p, arm: locked ? 25 : 9, gap: locked ? 17 : 0)
}

private func drawPeephole(_ c: Construction, _ ctx: CGContext, _ size: CGSize, locked: Bool, avoid: CGRect) {
    let p = viewPoint(c.principal, size: size)

    ctx.setFillColor(rgb(carraraHex, locked ? 1.0 : 0.92))
    annulus(ctx, p, inner: 8.8, outer: 11.5)
    ctx.setFillColor(rgb(holeHex, 0.88))
    annulus(ctx, p, inner: 4.2, outer: 8.8)

    if locked {
        ctx.setStrokeColor(rgb(sinopiaHex, 0.9))
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30))
        ctx.strokePath()
        drawLabel(ctx, "facing you", at: CGPoint(x: p.x, y: p.y + 30), anchor: .center, in: size,
                  font: Face.caption, color: rgb(sinopiaHex, 1.0), avoid: avoid)
    }
    drawLabel(ctx, "peephole", at: CGPoint(x: p.x, y: p.y - (locked ? 34 : 26)), anchor: .center,
              in: size, avoid: avoid)
}

private func cross(_ ctx: CGContext, at p: CGPoint, arm: CGFloat, gap: CGFloat) {
    ctx.beginPath()
    if gap > 0 {
        ctx.move(to: CGPoint(x: p.x - arm, y: p.y)); ctx.addLine(to: CGPoint(x: p.x - gap, y: p.y))
        ctx.move(to: CGPoint(x: p.x + gap, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y - arm)); ctx.addLine(to: CGPoint(x: p.x, y: p.y - gap))
        ctx.move(to: CGPoint(x: p.x, y: p.y + gap)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm))
    } else {
        ctx.move(to: CGPoint(x: p.x - arm, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y - arm)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm))
    }
    ctx.strokePath()
}

private func annulus(_ ctx: CGContext, _ c: CGPoint, inner: CGFloat, outer: CGFloat) {
    ctx.beginPath()
    ctx.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
    ctx.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
    ctx.fillPath(using: .evenOdd)
}

// MARK: - Readout

/// The instrument panel, bottom left. Laid out separately from its drawing because the labels
/// elsewhere on the panel need its rectangle to stay out from under.
private struct Readout {
    let plate: CGRect
    private let labels: [CTLine], values: [CTLine], suffixes: [CTLine]
    private let left, valueRight, suffixLeft: CGFloat
    private let ascent, leading, pad: CGFloat

    init(_ c: Construction, size: CGSize) {
        let ink = rgb(inkHex, 0.85)
        let font = Face.mono
        let rows: [(String, String, String)] = c.connected
            ? [("lid", String(format: "%.1f°", c.lidDeg), ""),
               ("normal", String(format: "%.1f°", c.elevationDeg), "above horizon"),
               ("peephole", String(format: "%.1f°", abs(c.offAxisDeg)), "off centre"),
               ("eye", String(format: "%.2f m", c.eyeDist), "")]
            : [("waiting for the wabe daemon — make && ./build/wabed", "", "")]

        labels = rows.map { line($0.0, font: font, color: ink) }
        values = rows.map { line($0.1, font: font, color: ink) }
        suffixes = rows.map { line($0.2, font: font, color: ink) }

        let wLabel = labels.map(textWidth).max() ?? 0
        let wValue = values.map(textWidth).max() ?? 0
        let wSuffix = suffixes.map(textWidth).max() ?? 0
        let gapValue: CGFloat = 10, gapSuffix: CGFloat = 8
        let content = wLabel + gapValue + wValue + (wSuffix > 0 ? gapSuffix + wSuffix : 0)

        ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        leading = ascent + descent + 4
        pad = 10
        let block = ascent + descent + leading * CGFloat(rows.count - 1)
        let margin: CGFloat = 16
        plate = CGRect(x: margin, y: margin,
                       width: min(content + pad * 2, max(0, size.width - margin * 2)),
                       height: block + pad * 2)
        left = plate.minX + pad
        valueRight = left + wLabel + gapValue + wValue
        suffixLeft = valueRight + gapSuffix
    }

    func draw(_ ctx: CGContext) {
        ctx.setFillColor(rgb(carraraHex, 0.86))
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(rgb(inkHex, 0.14))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5,
                           transform: nil))
        ctx.strokePath()

        for i in labels.indices {
            let baseline = plate.maxY - pad - ascent - leading * CGFloat(i)
            drawLine(ctx, labels[i], x: left, baseline: baseline)
            drawLine(ctx, values[i], x: valueRight - textWidth(values[i]), baseline: baseline)  // right-aligned
            drawLine(ctx, suffixes[i], x: suffixLeft, baseline: baseline)
        }
    }
}

// MARK: - Core Text helpers

private enum Anchor { case left, center }

private func drawLabel(_ ctx: CGContext, _ text: String, at p: CGPoint, anchor: Anchor, in size: CGSize,
                       font: CTFont = Face.label, color: CGColor = rgb(sinopiaHex, 0.95),
                       avoid: CGRect = .null) {
    let l = line(text.uppercased(), font: font, color: color, tracking: 0.9)
    let w = textWidth(l)
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    let m: CGFloat = 6
    var x = anchor == .left ? p.x : p.x - w / 2
    x = min(max(x, m), max(m, size.width - m - w))
    var y = min(max(p.y, m + descent), max(m + descent, size.height - m - ascent))

    var bg = CGRect(x: x - 4, y: y - descent - 2, width: w + 8, height: ascent + descent + 4)
    if bg.intersects(avoid) {
        // The readout only ever occupies a bottom corner, so up is always a way out.
        y = avoid.maxY + 6 + descent
        bg = CGRect(x: x - 4, y: y - descent - 2, width: w + 8, height: ascent + descent + 4)
    }
    ctx.setFillColor(rgb(carraraHex, 0.55))
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
    ctx.fillPath()
    drawLine(ctx, l, x: x, baseline: y)
}

private func line(_ s: String, font: CTFont, color: CGColor, tracking: Double = 0) -> CTLine {
    var attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if tracking != 0 {
        attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = NSNumber(value: tracking)
    }
    return CTLineCreateWithAttributedString(
        NSAttributedString(string: s, attributes: attrs) as CFAttributedString)
}

private func textWidth(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

private func drawLine(_ ctx: CGContext, _ l: CTLine, x: CGFloat, baseline: CGFloat) {
    ctx.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(l, ctx)
}
