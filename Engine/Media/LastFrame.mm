#include "LastFrame.h"

#include "../Model/TimeUtil.h"

namespace ve::media {

CMTime LastFrameSearch::firstStep(CMTime frameDuration) {
    const CMTime twoFrames = isPositive(frameDuration) ? frameDuration + frameDuration : kCMTimeZero;
    return maxTime(twoFrames, CMTimeMake(1, 4));
}

CMTime LastFrameSearch::nextStep(CMTime step) {
    return step + step;
}

CMTime LastFrameSearch::probe(CMTime from, CMTime step) {
    const CMTime at = from - step;
    return at < kCMTimeZero ? kCMTimeZero : at;
}

CMTime LastFrameSearch::searchFrom(CMTime time, CMTime trackStart, CMTime trackDuration) {
    if (!isNumeric(trackDuration)) {
        return time;
    }
    const CMTime end = (isNumeric(trackStart) ? trackStart : kCMTimeZero) + trackDuration;
    return isNumeric(time) ? minTime(time, end) : end;
}

Result<std::optional<VideoFrame>> LastFrameSearch::run(IVideoDecoder &decoder, CMTime from, CMTime frameDuration) {
    CMTime step = firstStep(frameDuration);
    for (;;) {
        const CMTime at = probe(from, step);
        if (Status st = decoder.seek(at); !st.ok()) {
            return std::move(st).error();
        }
        std::optional<VideoFrame> last;
        for (;;) {
            auto next = decoder.next();
            if (!next.ok()) {
                return std::move(next).error();
            }
            if (!next.value()) {
                break;
            }
            last = std::move(next).value();
        }
        if (last || !(at > kCMTimeZero)) {
            return last;
        }
        from = at;
        step = nextStep(step);
    }
}

} // namespace ve::media
