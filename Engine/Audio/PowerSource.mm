#include "PowerSource.h"

#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <dispatch/dispatch.h>
#include <notify.h>

#include <map>
#include <mutex>
#include <utility>

namespace ve::audio {

struct PowerSource::Observers {
    // Held while observers run, so a deregistration waits for a call in progress.
    std::mutex mutex;
    uint64_t nextId = 1;
    std::map<uint64_t, std::function<void()>> handlers;
};

PowerSource::PowerSource() : observers_(std::make_shared<Observers>()) {}

PowerSource::~PowerSource() = default;

std::unique_ptr<PowerSource::Observation> PowerSource::observe(std::function<void()> changed) {
    std::lock_guard<std::mutex> lock(observers_->mutex);
    const uint64_t id = observers_->nextId++;
    observers_->handlers.emplace(id, std::move(changed));
    return std::unique_ptr<Observation>(new Observation(observers_, id));
}

void PowerSource::notifyChanged() {
    std::lock_guard<std::mutex> lock(observers_->mutex);
    for (auto &[id, handler] : observers_->handlers) {
        if (handler) {
            handler();
        }
    }
}

PowerSource::Observation::Observation(std::weak_ptr<Observers> observers, uint64_t id)
    : observers_(std::move(observers)), id_(id) {}

PowerSource::Observation::~Observation() {
    if (auto observers = observers_.lock()) {
        std::lock_guard<std::mutex> lock(observers->mutex);
        observers->handlers.erase(id_);
    }
}

void ManualPowerSource::setOnBattery(bool onBattery) {
    if (onBattery_.exchange(onBattery, std::memory_order_acq_rel) != onBattery) {
        notifyChanged();
    }
}

namespace {

/// IOKit's answer: the source currently providing power is the internal battery.
bool readOnBattery() {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (info == nullptr) {
        return false; // no power source information (e.g. a Mac without a battery)
    }
    CFStringRef type = IOPSGetProvidingPowerSourceType(info); // Get rule: not retained
    const bool battery = type != nullptr && CFEqual(type, CFSTR(kIOPSBatteryPowerValue));
    CFRelease(info);
    return battery;
}

class SystemPowerSource final : public PowerSource {
  public:
    SystemPowerSource() : onBattery_(readOnBattery()) {
        queue_ = dispatch_queue_create("com.justjohn12345.framewright.power-source", DISPATCH_QUEUE_SERIAL);
        // The instance lives for the whole process (systemPowerSource()), so the handler's `this`
        // never dangles.
        const uint32_t status = notify_register_dispatch(kIOPSNotifyPowerSource, &token_, queue_, ^(int) {
          refresh();
        });
        registered_ = status == NOTIFY_STATUS_OK;
    }

    ~SystemPowerSource() override {
        if (registered_) {
            notify_cancel(token_);
        }
    }

    bool onBattery() const override { return onBattery_.load(std::memory_order_acquire); }

  private:
    void refresh() {
        const bool battery = readOnBattery();
        if (onBattery_.exchange(battery, std::memory_order_acq_rel) != battery) {
            notifyChanged();
        }
    }

    std::atomic<bool> onBattery_;
    dispatch_queue_t queue_ = nullptr;
    int token_ = NOTIFY_TOKEN_INVALID;
    bool registered_ = false;
};

} // namespace

std::shared_ptr<PowerSource> systemPowerSource() {
    // Never destroyed: the notification handler may run on its queue until the process ends.
    static const auto *source = new std::shared_ptr<PowerSource>(std::make_shared<SystemPowerSource>());
    return *source;
}

} // namespace ve::audio
