{ pkgs, drivers }:

pkgs.runCommand "graphics-driver-load-${pkgs.stdenv.hostPlatform.system}"
  {
    nativeBuildInputs = [ pkgs.stdenv.cc ];
  }
  ''
    $CC -Wall -Wextra -Werror ${../config/scripts/tests/graphics-driver-load.c} \
      -ldl -o graphics-driver-load

    # These cover the OpenGL vendor, X11 vendor, and dynamically loaded GBM/DRI
    # backend. Check every other installed driver too, including Vulkan ICDs.
    test -f ${drivers}/lib/libEGL_mesa.so.0
    test -f ${drivers}/lib/libGLX_mesa.so.0
    test -f ${drivers}/lib/gbm/dri_gbm.so
    found=0
    while IFS= read -r -d $'\0' library; do
      ./graphics-driver-load "$library"
      found=1
    done < <(find -L ${drivers}/lib -type f -name '*.so*' -print0)
    test "$found" -eq 1
    touch $out
  ''
