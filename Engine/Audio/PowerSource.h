// PowerSource: whether the Mac runs on its battery, for power-aware idle timeouts (the playback
// controller keeps its audio output running for a shorter time after the last transport activity
// on battery; see PlaybackConfig::outputIdleTimeoutOnBattery).
//
// systemPowerSource() asks IOKit (IOPSCopyPowerSourcesInfo + IOPSGetProvidingPowerSourceType) once
// and again whenever the system posts kIOPSNotifyPowerSource (a charger plugged in or out), so
// onBattery() is a cheap atomic read that the controller may call under its mutex. Observers are
// told after the answer may have changed, so a deadline computed from it can be re-evaluated at
// once. ManualPowerSource is set by hand (tests, or a caller with its own policy).
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>

namespace ve::audio {

class PowerSource {
  public:
    /// Keeps one observer registered; destroying it deregisters the observer, waiting for a call
    /// of it in progress (so the observer never runs after the Observation is gone). Move-only.
    class Observation;

    PowerSource();
    virtual ~PowerSource();
    PowerSource(const PowerSource &) = delete;
    PowerSource &operator=(const PowerSource &) = delete;

    /// True while the Mac draws power from its battery; false on AC power, on a UPS and on Macs
    /// without a battery. Thread-safe and cheap.
    virtual bool onBattery() const = 0;

    /// Calls `changed` (on an unspecified thread, never concurrently with itself) after onBattery()
    /// may have changed. `changed` must not register or destroy observations of this source.
    std::unique_ptr<Observation> observe(std::function<void()> changed);

  protected:
    /// Calls every observer (implementations call it after their answer changed).
    void notifyChanged();

  private:
    struct Observers;
    std::shared_ptr<Observers> observers_;
};

class PowerSource::Observation {
  public:
    ~Observation();
    Observation(const Observation &) = delete;
    Observation &operator=(const Observation &) = delete;

  private:
    friend class PowerSource;
    Observation(std::weak_ptr<Observers> observers, uint64_t id);
    std::weak_ptr<Observers> observers_;
    uint64_t id_ = 0;
};

/// The Mac's power source (see the header comment). One instance per process.
std::shared_ptr<PowerSource> systemPowerSource();

/// A power source whose answer is set by hand.
class ManualPowerSource final : public PowerSource {
  public:
    explicit ManualPowerSource(bool onBattery = false) : onBattery_(onBattery) {}
    bool onBattery() const override { return onBattery_.load(std::memory_order_acquire); }
    /// Changes the answer and tells the observers (when it changed).
    void setOnBattery(bool onBattery);

  private:
    std::atomic<bool> onBattery_;
};

} // namespace ve::audio
