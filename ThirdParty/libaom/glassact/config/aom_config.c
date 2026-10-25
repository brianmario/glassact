/*
 * Copyright (c) 2016, Alliance for Open Media. All rights reserved.
 *
 * This source code is subject to the terms of the BSD 2 Clause License and
 * the Alliance for Open Media Patent License 1.0. If the BSD 2 Clause License
 * was not distributed with this source code in the LICENSE file, you can
 * obtain it at www.aomedia.org/license/software. If the Alliance for Open
 * Media Patent License 1.0 was not distributed with this source code in the
 * PATENTS file, you can obtain it at www.aomedia.org/license/patent.
 */
#include "aom/aom_codec.h"
static const char* const cfg = "cmake ../../../../../../private/var/folders/vn/tcsv7f6j0p3_21qcxc8qhcsh0000gn/T/aom/src-main -G \"Unix Makefiles\" -DAOM_TARGET_CPU=arm64 -DCONFIG_AV1_DECODER=1 -DCONFIG_AV1_ENCODER=1 -DCONFIG_LIBYUV=0 -DCONFIG_AV1_HIGHBITDEPTH=0 -DCONFIG_REALTIME_ONLY=1 -DCONFIG_RUNTIME_CPU_DETECT=0 -DCONFIG_WEBM_IO=0 -DCONFIG_TUNE_BUTTERAUGLI=0 -DCONFIG_TUNE_VMAF=0 -DCONFIG_SALIENCY_MAP=0 -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 -DENABLE_ARM_CRC32=0 -DENABLE_NEON_DOTPROD=0 -DENABLE_NEON_I8MM=0 -DENABLE_SVE=0 -DENABLE_SVE2=0";
const char *aom_codec_build_config(void) {return cfg;}
