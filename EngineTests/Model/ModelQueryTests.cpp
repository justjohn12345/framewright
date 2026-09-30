// Small model queries the facade used to compute itself (moved out of VEEngine.mm): numericRange,
// requestedSequenceFormat, assetUseCounts and laneCount.

#include "ModelFixtures.h"

#include <climits>

using namespace vetest;

TEST_CASE("numericRange: the two ends of a numeric CMTimeRange") {
    const auto range = numericRange(CMTimeRangeMake(f30(10), f30(20)));
    REQUIRE(range);
    CHECK(range->start == f30(10));
    CHECK(range->end == f30(30));
    const auto empty = numericRange(CMTimeRangeMake(f30(10), kCMTimeZero));
    REQUIRE(empty);
    CHECK(empty->isEmpty());
    CHECK_FALSE(numericRange(kCMTimeRangeInvalid));
    CHECK_FALSE(numericRange(CMTimeRangeMake(kCMTimeInvalid, f30(1))));
    CHECK_FALSE(numericRange(CMTimeRangeMake(f30(1), kCMTimeIndefinite)));
    CHECK_FALSE(numericRange(CMTimeRangeMake(kCMTimeNegativeInfinity, f30(1))));
    CHECK_FALSE(numericRange(CMTimeRangeMake(f30(1), kCMTimePositiveInfinity)));
}

TEST_CASE("requestedSequenceFormat keeps values that fit and leaves the rest out of range") {
    const SequenceFormat format = requestedSequenceFormat(3840, 2160, CMTimeMake(1001, 24000), 96000);
    CHECK(format.width == 3840);
    CHECK(format.height == 2160);
    CHECK(format.frameDuration == CMTimeMake(1001, 24000));
    CHECK(format.audioSampleRate == 96000);
    CHECK(format.configured);
    CHECK_FALSE(sequenceFormatProblem(format));

    // Values past the model's 32-bit integers clamp to its limits instead of wrapping into range.
    const std::int64_t wraps = (std::int64_t(1) << 32) + 1920; // would wrap to 1920 as int32
    const SequenceFormat huge = requestedSequenceFormat(wraps, 1080, f30(1), 48000);
    CHECK(huge.width == INT32_MAX);
    CHECK(sequenceFormatProblem(huge));
    const SequenceFormat negative = requestedSequenceFormat(1920, -1080, f30(1), -48000);
    CHECK(negative.height == 0);
    CHECK(negative.audioSampleRate == 0);
    CHECK(sequenceFormatProblem(negative));
    CHECK(sequenceFormatProblem(requestedSequenceFormat(1920, 1080, f30(1), std::int64_t(1) << 40)));
}

TEST_CASE("assetUseCounts counts every sequence's clips per asset, in asset order") {
    Fixture fx;
    auto counts = assetUseCounts(fx.project);
    REQUIRE(counts.size() == fx.project.assets.size());
    for (std::size_t i = 0; i < counts.size(); ++i) {
        CHECK(counts[i].first == fx.project.assets[i].id);
        CHECK(counts[i].second == 0);
    }
    fx.addLinkedPair(0, 30);                     // av30 twice
    fx.addClip(fx.v2, fx.av30, 100, 30);         // av30 again
    fx.addClip(fx.a2, fx.audioOnly, 0, 30);      // music once
    // A second sequence counts too.
    const SequenceId other = fx.project.addSequence("Other", f30(1), 1920, 1080, 1, 1);
    Sequence &second = *fx.project.findSequence(other);
    Clip clip;
    clip.id = fx.project.ids.make<ClipId>();
    clip.assetId = fx.still;
    clip.trackId = second.videoTracks[0].id;
    clip.timelineStart = kCMTimeZero;
    clip.timelineDuration = f30(30);
    clip.isStill = true;
    second.videoTracks[0].clips.push_back(clip);
    counts = assetUseCounts(fx.project);
    auto countOf = [&](AssetId id) {
        for (const auto &[asset, uses] : counts) {
            if (asset == id) {
                return uses;
            }
        }
        FAIL("asset missing from the counts");
        return std::size_t(0);
    };
    CHECK(countOf(fx.av30) == 3);
    CHECK(countOf(fx.audioOnly) == 1);
    CHECK(countOf(fx.still) == 1);
    CHECK(countOf(fx.av24) == 0);
    CHECK(countOf(fx.video60) == 0);
}

TEST_CASE("laneCount is the highest lane a track's spans use, plus one") {
    Fixture fx;
    CHECK(laneCount(fx.track(fx.v1)) == 1);
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60);
    CHECK(laneCount(fx.track(fx.v1)) == 1);
    fx.addFade(a, ClipEdge::Head, f30(10)); // lane 0
    CHECK(laneCount(fx.track(fx.v1)) == 1);
    fx.addSpan(a, SpanKind::Motion, 2, f30(0), f30(30));
    CHECK(laneCount(fx.track(fx.v1)) == 3);
    fx.addSpan(b, SpanKind::Opacity, 3, f30(0), f30(30));
    CHECK(laneCount(fx.track(fx.v1)) == 4);
    CHECK(laneCount(fx.track(fx.v2)) == 1);
}
