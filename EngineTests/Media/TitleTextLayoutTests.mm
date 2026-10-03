// Point text, the vertical anchor and the text layout the program monitor's caret, selection and clicks use (titles
// slice 2, engine): the block's size and where it lies relative to the title's position, the picture following it,
// the empty last line after a line break, and the caret, the selection rectangles and the click mapping lining up
// with the glyphs the renderer draws (measured in the rendered picture, not from the layout itself).

#import <XCTest/XCTest.h>

#include "../../Engine/Media/TitleRenderer.h"

#include <cmath>
#include <vector>

using namespace ve;
using namespace ve::media;

namespace {

constexpr double kWidth = 1920;
constexpr double kHeight = 1080;

TitleContent plain(const char *text) {
    TitleContent content;
    content.text = text;
    content.shadow = false;
    content.size = 0.1;
    return content;
}

RenderedTitle renderAt(const TitleContent &content, double k = 1.0) {
    auto rendered = renderTitle(content, kWidth, kHeight, k);
    if (!rendered.ok()) {
        return RenderedTitle{};
    }
    return std::move(rendered).value();
}

/// The rendered picture's ink (the white fill: premultiplied green above `threshold`, so a black outline or box is not
/// ink) as canvas columns and rows relative to the title's position: per column whether it has ink, and the ink's
/// bounds.
struct Ink {
    double left = INFINITY;
    double right = -INFINITY;
    double top = INFINITY;
    double bottom = -INFINITY;
    std::vector<bool> columns; // per picture column
    double x0 = 0;             // the canvas x of column 0's left edge
    double pixel = 1;          // canvas pixels per picture pixel

    bool empty() const { return !(right >= left); }
    /// Whether any column between canvas x `a` and `b` has ink.
    bool inkBetween(double a, double b) const {
        for (std::size_t c = 0; c < columns.size(); ++c) {
            const double x = x0 + (double(c) + 0.5) * pixel;
            if (x > a && x < b && columns[c]) {
                return true;
            }
        }
        return false;
    }
};

Ink inkOf(const RenderedTitle &rendered, uint8_t threshold = 100) {
    Ink ink;
    CVPixelBufferRef pb = rendered.picture.get();
    const std::size_t width = CVPixelBufferGetWidth(pb);
    const std::size_t height = CVPixelBufferGetHeight(pb);
    ink.pixel = rendered.geometry.width / double(width);
    ink.x0 = rendered.geometry.x;
    ink.columns.assign(width, false);
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb));
    const std::size_t stride = CVPixelBufferGetBytesPerRow(pb);
    for (std::size_t y = 0; y < height; ++y) {
        for (std::size_t x = 0; x < width; ++x) {
            if (base[y * stride + x * 4 + 1] > threshold) {
                ink.columns[x] = true;
                ink.left = std::min(ink.left, rendered.geometry.x + double(x) * ink.pixel);
                ink.right = std::max(ink.right, rendered.geometry.x + double(x + 1) * ink.pixel);
                ink.top = std::min(ink.top, rendered.geometry.y + double(y) * ink.pixel);
                ink.bottom = std::max(ink.bottom, rendered.geometry.y + double(y + 1) * ink.pixel);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return ink;
}

} // namespace

@interface TitleTextLayoutTests : XCTestCase
@end

@implementation TitleTextLayoutTests

// MARK: - Point text and the anchor

- (void)testPointTextDoesNotWrapAndIsAsWideAsItsWidestLine {
    TitleContent area = plain("A long line of text that would wrap in a narrow box");
    area.width = 0.2;
    TitleContent point = area;
    point.pointText = true;
    const TitleBlockSize wrapped = measureTitleBlock(area, kWidth, kHeight);
    const TitleBlockSize single = measureTitleBlock(point, kWidth, kHeight);
    const TitleTextLayout pointLayout = TitleTextLayout::make(point, kWidth, kHeight);
    XCTAssertEqual(pointLayout.lineCount(), 1u, @"point text breaks only at line breaks");
    XCTAssertGreaterThan(TitleTextLayout::make(area, kWidth, kHeight).lineCount(), 2u);
    XCTAssertGreaterThan(single.width, 0.2 * kWidth * 2, @"as wide as its line, not the box");
    XCTAssertLessThan(single.height, wrapped.height / 2);
    // Its width is its line's visible width: the rendered ink spans it (the side bearings aside).
    const Ink ink = inkOf(renderAt(point));
    XCTAssertEqualWithAccuracy(ink.right - ink.left, single.width, 0.02 * single.width);
    // Two lines: the widest one.
    TitleContent two = point;
    two.text = "Short\nA much longer second line";
    TitleContent second = point;
    second.text = "A much longer second line";
    XCTAssertEqualWithAccuracy(measureTitleBlock(two, kWidth, kHeight).width,
                               measureTitleBlock(second, kWidth, kHeight).width, 1e-6);
}

- (void)testPointTextGrowsAwayFromItsPositionAsItAligns {
    // Left: x is the block's left edge, and typing grows it to the right.
    for (const TitleAlignment alignment : {TitleAlignment::Left, TitleAlignment::Centre, TitleAlignment::Right}) {
        TitleContent shorter = plain("Grow");
        shorter.pointText = true;
        shorter.alignment = alignment;
        TitleContent longer = shorter;
        longer.text = "Growing";
        const TitleBlockSize a = measureTitleBlock(shorter, kWidth, kHeight);
        const TitleBlockSize b = measureTitleBlock(longer, kWidth, kHeight);
        const double flush = alignment == TitleAlignment::Left ? 0.0 : alignment == TitleAlignment::Right ? 1.0 : 0.5;
        XCTAssertEqualWithAccuracy(a.left, -flush * a.width, 1e-9);
        XCTAssertEqualWithAccuracy(b.left, -flush * b.width, 1e-9);
        // The rendered ink follows: its left edge stays (left), its centre (centre), its right edge (right).
        const Ink inkA = inkOf(renderAt(shorter));
        const Ink inkB = inkOf(renderAt(longer));
        const double anchoredA = inkA.left + flush * (inkA.right - inkA.left);
        const double anchoredB = inkB.left + flush * (inkB.right - inkB.left);
        XCTAssertEqualWithAccuracy(anchoredA, 0.0, 8.0, @"alignment %d", int(alignment));
        XCTAssertEqualWithAccuracy(anchoredB, 0.0, 8.0, @"alignment %d", int(alignment));
        XCTAssertGreaterThan(inkB.right - inkB.left, inkA.right - inkA.left + 50);
    }
    // Area text stays centred on x whatever its alignment (slice 1).
    TitleContent area = plain("Area");
    area.alignment = TitleAlignment::Left;
    XCTAssertEqualWithAccuracy(measureTitleBlock(area, kWidth, kHeight).left, -0.8 * kWidth / 2, 1e-9);
}

- (void)testTheAnchorSetsWhichWayTheBlockGrows {
    for (const TitleAnchor anchor : {TitleAnchor::Top, TitleAnchor::Centre, TitleAnchor::Bottom}) {
        TitleContent one = plain("First");
        one.anchor = anchor;
        TitleContent two = one;
        two.text = "First\nSecond";
        const TitleBlockSize a = measureTitleBlock(one, kWidth, kHeight);
        const TitleBlockSize b = measureTitleBlock(two, kWidth, kHeight);
        const double at = anchor == TitleAnchor::Top ? 0.0 : anchor == TitleAnchor::Bottom ? 1.0 : 0.5;
        XCTAssertEqualWithAccuracy(a.top, -at * a.height, 1e-9);
        XCTAssertEqualWithAccuracy(b.top, -at * b.height, 1e-9);
        const Ink inkA = inkOf(renderAt(one));
        const Ink inkB = inkOf(renderAt(two));
        if (anchor == TitleAnchor::Top) {
            // The first line stays where it was: the second is added below it.
            XCTAssertEqualWithAccuracy(inkB.top, inkA.top, 1.0);
            XCTAssertGreaterThan(inkB.bottom, inkA.bottom + 0.05 * kHeight);
            XCTAssertGreaterThan(inkA.top, 0.0);
            XCTAssertLessThan(inkA.top, 0.1 * kHeight * 0.5);
        } else if (anchor == TitleAnchor::Bottom) {
            // The last line stays at the bottom: the block grows up.
            XCTAssertLessThan(inkB.top, inkA.top - 0.05 * kHeight);
            XCTAssertLessThan(inkA.bottom, 0.0);
            XCTAssertGreaterThan(inkA.bottom, -0.1 * kHeight * 0.5);
        } else {
            XCTAssertLessThan(inkA.top, 0.0);
            XCTAssertGreaterThan(inkA.bottom, 0.0);
        }
    }
}

- (void)testATrailingLineBreakAddsAnEmptyLineToTheBlock {
    const TitleBlockSize one = measureTitleBlock(plain("Line"), kWidth, kHeight);
    const TitleBlockSize broken = measureTitleBlock(plain("Line\n"), kWidth, kHeight);
    const TitleBlockSize two = measureTitleBlock(plain("Line\nLine"), kWidth, kHeight);
    XCTAssertEqualWithAccuracy(broken.height, two.height, 1e-6, @"the empty last line is a line of the font");
    XCTAssertGreaterThan(broken.height, one.height * 1.5);
    // An empty text is one empty line (where the caret goes), and draws nothing.
    XCTAssertEqualWithAccuracy(measureTitleBlock(plain(""), kWidth, kHeight).height, one.height, 1e-6);
    XCTAssertTrue(inkOf(renderAt(plain(""))).empty());
    const TitleTextLayout layout = TitleTextLayout::make(plain("Line\n"), kWidth, kHeight);
    XCTAssertEqual(layout.lineCount(), 2u);
    XCTAssertEqual(layout.lineOf(5), 1u, @"after the break: the new line");
    XCTAssertEqual(layout.lineOf(4), 0u, @"before it: the first");
    XCTAssertGreaterThan(layout.caret(5).top, layout.caret(4).bottom - 1);
}

// MARK: - The caret, the selection and clicks against the drawn glyphs

/// For "H H" laid out with `content`'s alignment, point text and anchor: the carets bracket the glyphs as the
/// renderer drew them, the selection of the first H covers its ink and not the second's, and a click on each half
/// of each H gives the caret before or after it.
- (void)checkCaretsAgainstTheGlyphs:(TitleContent)content {
    content.text = "H H";
    const TitleTextLayout layout = TitleTextLayout::make(content, kWidth, kHeight);
    const RenderedTitle rendered = renderAt(content);
    const Ink ink = inkOf(rendered);
    XCTAssertFalse(ink.empty());
    // The ink of each H: the columns with ink left and right of the gap.
    const TitleTextLayout::Caret c0 = layout.caret(0), c1 = layout.caret(1), c2 = layout.caret(2), c3 = layout.caret(3);
    XCTAssertFalse(ink.inkBetween(c1.x + 0.5, c2.x - 0.5), @"no ink between the first H's end and the second's start");
    XCTAssertTrue(ink.inkBetween(c0.x, c1.x), @"the first H lies between carets 0 and 1");
    XCTAssertTrue(ink.inkBetween(c2.x, c3.x), @"the second H between carets 2 and 3");
    XCTAssertFalse(ink.inkBetween(-1e9, c0.x - 1.0), @"nothing before caret 0");
    XCTAssertFalse(ink.inkBetween(c3.x + 1.0, 1e9), @"nothing after caret 3");
    XCTAssertLessThanOrEqual(c0.x, ink.left + 0.5);
    XCTAssertGreaterThanOrEqual(c3.x, ink.right - 0.5);
    // Vertically: the caret spans the H (its ascent above, its descent below).
    XCTAssertLessThanOrEqual(c0.top, ink.top + 0.5);
    XCTAssertGreaterThanOrEqual(c0.bottom, ink.bottom - 0.5);
    XCTAssertLessThan(ink.bottom - ink.top, c0.bottom - c0.top);
    // The selection of the first H covers its ink, and only it.
    const std::vector<CGRect> rects = layout.selectionRects(0, 1);
    XCTAssertEqual(rects.size(), 1u);
    if (!rects.empty()) {
        const CGRect r = rects[0];
        XCTAssertEqualWithAccuracy(CGRectGetMinX(r), c0.x, 0.5);
        XCTAssertEqualWithAccuracy(CGRectGetMaxX(r), c1.x, 0.5);
        XCTAssertLessThanOrEqual(CGRectGetMinY(r), ink.top + 0.5);
        XCTAssertGreaterThanOrEqual(CGRectGetMaxY(r), ink.bottom - 0.5);
    }
    // Clicks: the left part of the first H gives 0, its right part 1, the second H's right part 3.
    const double middle = (ink.top + ink.bottom) / 2;
    XCTAssertEqual(layout.indexAt(CGPointMake(c0.x + 0.2 * (c1.x - c0.x), middle)), 0);
    XCTAssertEqual(layout.indexAt(CGPointMake(c0.x + 0.8 * (c1.x - c0.x), middle)), 1);
    XCTAssertEqual(layout.indexAt(CGPointMake(c2.x + 0.8 * (c3.x - c2.x), middle)), 3);
    XCTAssertEqual(layout.indexAt(CGPointMake(c3.x + 500, middle)), 3, @"past the end: the end");
    XCTAssertEqual(layout.indexAt(CGPointMake(c0.x - 500, middle - 500)), 0, @"above and before: the start");
}

- (void)testTheCaretAndSelectionLineUpWithTheDrawnGlyphs {
    for (const TitleAlignment alignment : {TitleAlignment::Left, TitleAlignment::Centre, TitleAlignment::Right}) {
        for (const bool point : {false, true}) {
            for (const TitleAnchor anchor : {TitleAnchor::Top, TitleAnchor::Centre, TitleAnchor::Bottom}) {
                TitleContent content = plain("");
                content.alignment = alignment;
                content.pointText = point;
                content.anchor = anchor;
                content.tracking = 80;
                [self checkCaretsAgainstTheGlyphs:content];
            }
        }
    }
    // With an outline and a box the glyphs are where they were.
    TitleContent styled = plain("");
    styled.outline = true;
    styled.box = true;
    [self checkCaretsAgainstTheGlyphs:styled];
}

- (void)testLinesCaretsAndUpAndDown {
    TitleContent content = plain("One\nTwo three four five six seven\n\nEnd");
    content.width = 0.4; // the second paragraph wraps
    const TitleTextLayout layout = TitleTextLayout::make(content, kWidth, kHeight);
    XCTAssertGreaterThanOrEqual(layout.lineCount(), 5u);
    // The first line ends before its break: a click past it stays on it.
    const TitleTextLayout::Line &first = layout.line(0);
    XCTAssertTrue(first.endsWithBreak);
    XCTAssertEqual(layout.indexAt(CGPointMake(first.left + 2000, first.baseline)), 3);
    XCTAssertEqual(layout.indexOnLine(0, 1e6), 3);
    // A wrapped line: the caret at its end index shows at the start of the next line; a click past its end stays on it.
    const TitleTextLayout::Line &wrapped = layout.line(1);
    XCTAssertFalse(wrapped.endsWithBreak);
    const CFIndex wrappedEnd = wrapped.start + wrapped.length;
    XCTAssertEqual(layout.lineOf(wrappedEnd), 2u);
    XCTAssertEqual(layout.indexOnLine(1, 1e6), wrappedEnd - 1);
    XCTAssertEqual(layout.lineOf(layout.indexOnLine(1, 1e6)), 1u);
    // Lines go down the block.
    for (std::size_t i = 1; i < layout.lineCount(); ++i) {
        XCTAssertGreaterThan(layout.line(i).baseline, layout.line(i - 1).baseline);
    }
    // Up and down: the index on the line above at the caret's x.
    const CFIndex t = 4; // "T" of "Two"
    const TitleTextLayout::Caret caret = layout.caret(t + 1);
    XCTAssertEqual(layout.lineOf(layout.indexOnLine(0, caret.x)), 0u);
    XCTAssertEqual(layout.indexOnLine(0, layout.caret(1).x), 1);
    // The empty paragraph's line: its caret is at its start.
    std::size_t empty = 0;
    for (std::size_t i = 0; i < layout.lineCount(); ++i) {
        if (layout.line(i).length == 1 && layout.line(i).endsWithBreak) {
            empty = i;
        }
    }
    XCTAssertGreaterThan(empty, 0u);
    XCTAssertEqual(layout.indexOnLine(empty, 1e6), layout.line(empty).start);
    // A selection over the break between lines covers both lines and the break.
    const std::vector<CGRect> rects = layout.selectionRects(1, 6);
    XCTAssertEqual(rects.size(), 2u);
    if (rects.size() == 2) {
        XCTAssertLessThan(CGRectGetMaxY(rects[0]), CGRectGetMinY(rects[1]) + 1.0);
        XCTAssertGreaterThan(CGRectGetMaxX(rects[0]), layout.caret(3).x, @"the selected break shows past the line");
    }
    XCTAssertTrue(layout.selectionRects(3, 3).empty());
    // The end of the text: the last line.
    XCTAssertEqual(layout.lineOf(layout.length()), layout.lineCount() - 1);
}

- (void)testSurrogatesAndRightToLeftText {
    // An emoji is two UTF-16 units: clicks never land between them.
    TitleContent emoji = plain("a🎬b");
    const TitleTextLayout layout = TitleTextLayout::make(emoji, kWidth, kHeight);
    XCTAssertEqual(layout.length(), 4);
    const double y = layout.line(0).baseline - 10;
    for (double x = layout.caret(0).x; x <= layout.caret(4).x; x += 2.0) {
        XCTAssertNotEqual(layout.indexAt(CGPointMake(x, y)), 2);
    }
    // Right-to-left text: selecting its first letter selects where that letter is drawn, at the right.
    TitleContent hebrew = plain("שלום");
    hebrew.pointText = true;
    const TitleTextLayout rtl = TitleTextLayout::make(hebrew, kWidth, kHeight);
    const std::vector<CGRect> first = rtl.selectionRects(0, 1);
    const std::vector<CGRect> last = rtl.selectionRects(3, 4);
    XCTAssertEqual(first.size(), 1u);
    XCTAssertEqual(last.size(), 1u);
    if (!first.empty() && !last.empty()) {
        XCTAssertGreaterThan(CGRectGetMinX(first[0]), CGRectGetMinX(last[0]));
    }
}

@end
