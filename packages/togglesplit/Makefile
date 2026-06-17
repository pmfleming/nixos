# Minimal Hyprland plugin build, based on official hyprland-plugins examples.

ifeq ($(CXX),g++)
    EXTRA_FLAGS = --no-gnu-unique
else
    EXTRA_FLAGS =
endif

CXXFLAGS ?= -O2
CXXFLAGS += -shared -fPIC -std=c++2b

PKGS = pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon

all:
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(EXTRA_FLAGS) src/main.cpp -o togglesplit.so `pkg-config --cflags $(PKGS)`

clean:
	rm -f togglesplit.so
