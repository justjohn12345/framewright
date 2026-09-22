#pragma once

#include "../Interfaces.h"

namespace ve::media::apple {

/// IMediaProber over ImageIO (stills) and AVURLAsset (everything else). Stateless and
/// thread-safe. AVURLAsset loads asynchronously; probe() blocks on it for at most
/// `loadTimeoutSeconds`.
class AppleProber final : public IMediaProber {
  public:
    explicit AppleProber(double loadTimeoutSeconds);
    Result<MediaInfo> probe(const std::string &path) override;

  private:
    double timeout_;
};

} // namespace ve::media::apple
