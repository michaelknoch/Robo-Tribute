#pragma once
#include <JavaScriptCore/JSContextRef.h>
#include <stdbool.h>

// Exported by JavaScriptCore but only declared in its private JSContextRefPrivate.h.
typedef bool (*JSShouldTerminateCallback)(JSContextRef ctx, void *context);
JS_EXPORT void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit,
                                                   JSShouldTerminateCallback callback, void *context);
