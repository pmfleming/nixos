#define WLR_USE_UNSTABLE

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>

#include <stdexcept>
#include <string>

namespace {

using BoolValue  = Config::Values::CBoolValue;
using FloatValue = Config::Values::CFloatValue;
using NewTarget  = void (*)(Layout::CLayoutManager*, SP<Layout::ITarget>, SP<Layout::CSpace>);

enum class Axis { Horizontal, Vertical };

HANDLE         PHANDLE          = nullptr;
CFunctionHook* g_newTargetHook  = nullptr;
Axis           g_lastAxis       = Axis::Vertical;

struct {
    SP<BoolValue>  enabled;
    SP<FloatValue> wideRatio;
    SP<FloatValue> tallRatio;
    SP<FloatValue> minWidth;
    SP<FloatValue> minHeight;
} cfg;

Axis alternateAxis() {
    return g_lastAxis == Axis::Horizontal ? Axis::Vertical : Axis::Horizontal;
}

Axis chooseAxis() {
    const auto WINDOW = Desktop::focusState()->window();
    if (!WINDOW || WINDOW->m_isFloating || !WINDOW->m_isMapped)
        return alternateAxis();

    const auto BOX = WINDOW->getWindowMainSurfaceBox();
    if (BOX.w <= 0 || BOX.h <= 0)
        return alternateAxis();

    const float ASPECT = BOX.w / BOX.h;
    Axis        axis   = ASPECT >= cfg.wideRatio->value()       ? Axis::Horizontal :
                         1.F / ASPECT >= cfg.tallRatio->value() ? Axis::Vertical :
                                                                  alternateAxis();

    if (axis == Axis::Horizontal && cfg.minWidth->value() > 0.F && BOX.w / 2.F < cfg.minWidth->value())
        return Axis::Vertical;
    if (axis == Axis::Vertical && cfg.minHeight->value() > 0.F && BOX.h / 2.F < cfg.minHeight->value())
        return Axis::Horizontal;
    return axis;
}

void preselect(Layout::CLayoutManager* layout, SP<Layout::ITarget> target) {
    if (!cfg.enabled->value() || !target || target->floating())
        return;

    g_lastAxis = chooseAxis();
    layout->layoutMsg(g_lastAxis == Axis::Horizontal ? "preselect right" : "preselect down");
}

void hkNewTarget(Layout::CLayoutManager* self, SP<Layout::ITarget> target, SP<Layout::CSpace> space) {
    preselect(self, target);
    (*(NewTarget)g_newTargetHook->m_original)(self, target, space);
}

void notify(const std::string& message, const CHyprColor& color, uint64_t timeout = 3000) {
    HyprlandAPI::addNotification(PHANDLE, message, color, timeout);
}

template <typename T>
SP<T> addConfig(SP<T> value) {
    HyprlandAPI::addConfigValueV2(PHANDLE, value);
    return value;
}

void addConfigValues() {
    using Config::Values::SFloatValueOptions;

    cfg.enabled   = addConfig(makeShared<BoolValue>("plugin:togglesplit:enabled", "Enable smart alternating split preselection.", true));
    cfg.wideRatio = addConfig(makeShared<FloatValue>("plugin:togglesplit:wide_ratio", "Force left/right splits when focused tile is wider than this ratio.", 1.35F,
                                                     SFloatValueOptions{.min = 1.F, .max = 10.F}));
    cfg.tallRatio = addConfig(makeShared<FloatValue>("plugin:togglesplit:tall_ratio", "Force up/down splits when focused tile is taller than this ratio.", 1.35F,
                                                     SFloatValueOptions{.min = 1.F, .max = 10.F}));
    cfg.minWidth  = addConfig(makeShared<FloatValue>("plugin:togglesplit:min_width", "Avoid left/right splits that would make a tile narrower than this. 0 disables.", 0.F,
                                                     SFloatValueOptions{.min = 0.F, .max = 10000.F}));
    cfg.minHeight = addConfig(makeShared<FloatValue>("plugin:togglesplit:min_height", "Avoid up/down splits that would make a tile shorter than this. 0 disables.", 0.F,
                                                     SFloatValueOptions{.min = 0.F, .max = 10000.F}));
}

void hookNewTarget() {
    for (const auto& fn : HyprlandAPI::findFunctionsByName(PHANDLE, "newTarget")) {
        if (!fn.demangled.contains("CLayoutManager"))
            continue;
        g_newTargetHook = HyprlandAPI::createFunctionHook(PHANDLE, fn.address, (void*)::hkNewTarget);
        break;
    }

    if (!g_newTargetHook)
        throw std::runtime_error("[togglesplit] Failed to find CLayoutManager::newTarget");
    if (!g_newTargetHook->hook())
        throw std::runtime_error("[togglesplit] Failed to hook CLayoutManager::newTarget");
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    if (std::string{__hyprland_api_get_hash()} != __hyprland_api_get_client_hash()) {
        notify("[togglesplit] Version mismatch between Hyprland and plugin headers", CHyprColor{1.F, 0.2F, 0.2F, 1.F}, 5000);
        throw std::runtime_error("[togglesplit] Version mismatch");
    }

    addConfigValues();
    hookNewTarget();
    notify("[togglesplit] loaded", CHyprColor{0.2F, 1.F, 0.2F, 1.F});

    return {"togglesplit", "Smart alternating split direction for Hyprland", "pmfleming", "0.3.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    cfg = {};
    notify("[togglesplit] unloaded", CHyprColor{1.F, 0.8F, 0.2F, 1.F});
}
