#pragma once

// A baseline JPEG encoder for the camera's pictures and JPEG image streams:
// JFIF, YCbCr without chroma subsampling, the example quantization and
// Huffman tables of the JPEG standard (Annex K), the quantization tables
// scaled by quality the way libjpeg scales them.

#include <cstddef>
#include <cstdint>
#include <vector>

namespace raccoon {

// |bgra| is |height| rows of |stride| bytes, four bytes a pixel, blue first;
// alpha is ignored. |quality| runs from 1 to 100.
std::vector<uint8_t> EncodeJpeg(const uint8_t* bgra, size_t width, size_t height,
                                size_t stride, int quality);

}  // namespace raccoon
