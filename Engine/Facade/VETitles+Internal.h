// Obj-C++ conversions between the facade's title types (VETitles.h) and the model's (GeneratedContent.h, TitleEdits.h).
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import "VETitles.h"

#include "../Edit/TitleEdits.h"
#include "../Model/GeneratedContent.h"

#include <optional>

namespace ve::facade {

VEColour toVE(const SRGBColour &colour);
SRGBColour fromVE(const VEColour &colour);
VETitleParameter toVE(TitleParameter parameter);
/// Nullopt for a value outside the enumeration.
std::optional<TitleParameter> fromVE(VETitleParameter parameter);
VETitleAlignment toVE(TitleAlignment alignment);
/// Nullopt for a value outside the enumeration.
std::optional<TitleAlignment> fromVE(VETitleAlignment alignment);
VEGeneratorKind toVE(GeneratorKind kind);
/// Nullopt for a value outside the enumeration.
std::optional<GeneratedPreset> fromVE(VEGeneratedPreset preset);
VETitleFont *makeTitleFont(const TitleFont &font);
/// Nullopt for a font that is not valid (an installed font without a PostScript name, a weight outside the enum).
std::optional<TitleFont> fromVE(VETitleFont *font);
VETitleInfo *makeTitleInfo(const TitleContent &content);
VETitleSelection *makeTitleSelection(const TitleSummary &summary, const Sequence &sequence);
VEMissingTitleFont *makeMissingTitleFont(const TitleFont &font, NSInteger clipCount);

/// Whether this Mac has `font` (media::isTitleFontAvailable), remembered per font until
/// forgetTitleFontAvailability (the Mac's fonts changed). Main thread only.
bool isTitleFontAvailableCached(const TitleFont &font);
void forgetTitleFontAvailability();

} // namespace ve::facade
