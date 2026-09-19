// Match kitty's accelerated macOS core-profile requirement. Exit 2 means this
// host needs the documented physical-Mac acceptance check before publication.
#include <OpenGL/OpenGL.h>
#include <stdio.h>
int main(void) {
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAAccelerated, kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core, 0
    };
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count = 0;
    CGLError error = CGLChoosePixelFormat(attributes, &format, &count);
    if (error == kCGLBadPixelFormat || (error == kCGLNoError && (!format || !count))) {
        puts("UNAVAILABLE: accelerated OpenGL core profile; kitty requires physical-Mac acceptance");
        if (format) CGLDestroyPixelFormat(format);
        return 2;
    }
    if (error != kCGLNoError) { fprintf(stderr, "%s\n", CGLErrorString(error)); return 1; }
    error = CGLCreateContext(format, NULL, &context);
    CGLDestroyPixelFormat(format);
    if (error != kCGLNoError) { fprintf(stderr, "%s\n", CGLErrorString(error)); return 1; }
    CGLDestroyContext(context);
    puts("AVAILABLE: accelerated OpenGL core profile");
    return 0;
}
