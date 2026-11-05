/* No renderer or GPU access: exercise the application's actual libc loader. */
#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: graphics-driver-load LIBRARY\n");
        return 2;
    }
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "glibc %s cannot load %s: %s\n",
                gnu_get_libc_version(), argv[1], dlerror());
        return 1;
    }
    printf("glibc %s loaded %s\n", gnu_get_libc_version(), argv[1]);
    dlclose(handle);
    return 0;
}
