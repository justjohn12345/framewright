// Non-owning reference to a callable (like C++26 std::function_ref): never allocates, so it can
// be built from a capturing lambda on every frame. The referenced callable must outlive the
// FunctionRef (pass it down a call chain, never store it).

#pragma once

#include <memory>
#include <type_traits>
#include <utility>

namespace ve::render {

template <class Signature> class FunctionRef;

template <class R, class... Args> class FunctionRef<R(Args...)> {
  public:
    template <class F, std::enable_if_t<!std::is_same_v<std::decay_t<F>, FunctionRef> &&
                                            std::is_invocable_r_v<R, F &, Args...>,
                                        int> = 0>
    FunctionRef(F &&callable) noexcept // NOLINT(google-explicit-constructor)
        : object_(const_cast<void *>(static_cast<const void *>(std::addressof(callable)))),
          invoke_([](void *object, Args... args) -> R {
              return (*static_cast<std::remove_reference_t<F> *>(object))(std::forward<Args>(args)...);
          }) {}

    R operator()(Args... args) const { return invoke_(object_, std::forward<Args>(args)...); }

  private:
    void *object_;
    R (*invoke_)(void *, Args...);
};

} // namespace ve::render
