// A TrueType font made by the tests themselves (no font file in the repository, none of the Mac's fonts copied):
// every printable ASCII character but the space is a solid box (500 x 700 of 1000 units, on the baseline), the
// space is empty. Registered for the test process (CTFontManagerRegisterFontsForURL, kCTFontManagerScopeProcess), it
// is a font this Mac does not otherwise have, so a title naming it is drawn in the fallback until it is registered
// and in boxes after: a font change a test can make and see.

#pragma once

#include <string>

namespace ve::test {

/// Writes the box font, named `family` (style "Regular") with the PostScript name `postScriptName`, to `path`.
/// Returns "" or what went wrong.
std::string writeBoxFont(const std::string &path, const std::string &family, const std::string &postScriptName);

} // namespace ve::test
