#include "jpeg_encoder.h"

#include <algorithm>
#include <cmath>

namespace raccoon {

namespace {

// The order coefficients are written in: the natural (row-major) index of
// each zig-zag position.
constexpr uint8_t kZigzag[64] = {
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

// Annex K.1, in natural order.
constexpr uint8_t kLumaQuant[64] = {
    16, 11, 10, 16, 24,  40,  51,  61,  12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,  14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,  24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99};
constexpr uint8_t kChromaQuant[64] = {
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99};

// Annex K.3: how many codes of each length, 1 to 16, then the symbols.
constexpr uint8_t kLumaDcBits[16] = {0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0};
constexpr uint8_t kChromaDcBits[16] = {0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0};
constexpr uint8_t kDcValues[12] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};

constexpr uint8_t kLumaAcBits[16] = {0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d};
constexpr uint8_t kLumaAcValues[162] = {
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51,
    0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1,
    0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18,
    0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57,
    0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92,
    0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8,
    0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2,
    0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa};

constexpr uint8_t kChromaAcBits[16] = {0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77};
constexpr uint8_t kChromaAcValues[162] = {
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07,
    0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09,
    0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25,
    0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56,
    0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74,
    0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
    0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6,
    0xd7, 0xd8, 0xd9, 0xda, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2,
    0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa};

// A Huffman table as codes by symbol: the code and its length in bits.
struct HuffmanTable {
  uint16_t code[256] = {};
  uint8_t length[256] = {};
};

HuffmanTable BuildTable(const uint8_t bits[16], const uint8_t* values) {
  HuffmanTable table;
  uint16_t code = 0;
  size_t k = 0;
  for (int length = 1; length <= 16; ++length) {
    for (int i = 0; i < bits[length - 1]; ++i) {
      table.code[values[k]] = code;
      table.length[values[k]] = static_cast<uint8_t>(length);
      ++code;
      ++k;
    }
    code = static_cast<uint16_t>(code << 1);
  }
  return table;
}

// The table scaled for |quality|, as libjpeg scales it.
void ScaleQuant(const uint8_t base[64], int quality, uint8_t out[64]) {
  const int scale = quality < 50 ? 5000 / quality : 200 - quality * 2;
  for (int i = 0; i < 64; ++i) {
    out[i] = static_cast<uint8_t>(std::clamp((base[i] * scale + 50) / 100, 1, 255));
  }
}

class BitWriter {
 public:
  explicit BitWriter(std::vector<uint8_t>* out) : out_(out) {}

  void Write(uint32_t bits, int count) {
    for (int i = count - 1; i >= 0; --i) {
      byte_ = static_cast<uint8_t>((byte_ << 1) | ((bits >> i) & 1));
      if (++filled_ == 8) Flush();
    }
  }

  // Pads the last byte with ones, as the standard asks.
  void Finish() {
    while (filled_ != 0) Write(1, 1);
  }

 private:
  void Flush() {
    out_->push_back(byte_);
    // A 0xFF in the data is followed by a zero, so it reads as no marker.
    if (byte_ == 0xFF) out_->push_back(0);
    byte_ = 0;
    filled_ = 0;
  }

  std::vector<uint8_t>* out_;
  uint8_t byte_ = 0;
  int filled_ = 0;
};

// The number of bits |value|'s magnitude takes: its category.
int Category(int value) {
  int magnitude = value < 0 ? -value : value;
  int bits = 0;
  while (magnitude != 0) {
    ++bits;
    magnitude >>= 1;
  }
  return bits;
}

// A value of its category's bits: negative values as their ones' complement.
uint32_t Amplitude(int value, int category) {
  const int bits = value < 0 ? value - 1 : value;
  return static_cast<uint32_t>(bits) & ((1u << category) - 1);
}

class BlockEncoder {
 public:
  BlockEncoder() {
    for (int u = 0; u < 8; ++u) {
      for (int x = 0; x < 8; ++x) {
        cosines_[u][x] = std::cos((2 * x + 1) * u * 3.14159265358979323846 / 16);
      }
    }
  }

  // Transforms, quantizes and writes one 8x8 block of samples, level
  // shifted; |previous_dc| is the component's last DC value.
  void Encode(const float samples[64], const uint8_t quant[64], const HuffmanTable& dc,
              const HuffmanTable& ac, int* previous_dc, BitWriter* writer) const {
    // Rows, then columns.
    double rows[64];
    for (int y = 0; y < 8; ++y) {
      for (int u = 0; u < 8; ++u) {
        double sum = 0;
        for (int x = 0; x < 8; ++x) sum += samples[y * 8 + x] * cosines_[u][x];
        rows[y * 8 + u] = sum;
      }
    }
    int coefficients[64];
    for (int v = 0; v < 8; ++v) {
      for (int u = 0; u < 8; ++u) {
        double sum = 0;
        for (int y = 0; y < 8; ++y) sum += rows[y * 8 + u] * cosines_[v][y];
        const double cu = u == 0 ? 1 / std::sqrt(2.0) : 1;
        const double cv = v == 0 ? 1 / std::sqrt(2.0) : 1;
        const double value = sum * cu * cv / 4;
        coefficients[v * 8 + u] = static_cast<int>(std::lround(value / quant[v * 8 + u]));
      }
    }

    const int diff = coefficients[0] - *previous_dc;
    *previous_dc = coefficients[0];
    const int dc_category = Category(diff);
    writer->Write(dc.code[dc_category], dc.length[dc_category]);
    writer->Write(Amplitude(diff, dc_category), dc_category);

    int zeros = 0;
    for (int i = 1; i < 64; ++i) {
      const int value = coefficients[kZigzag[i]];
      if (value == 0) {
        ++zeros;
        continue;
      }
      // Sixteen zeros at a time, as ZRL.
      while (zeros >= 16) {
        writer->Write(ac.code[0xF0], ac.length[0xF0]);
        zeros -= 16;
      }
      const int category = Category(value);
      const int symbol = (zeros << 4) | category;
      writer->Write(ac.code[symbol], ac.length[symbol]);
      writer->Write(Amplitude(value, category), category);
      zeros = 0;
    }
    // End of block, for trailing zeros.
    if (zeros > 0) writer->Write(ac.code[0x00], ac.length[0x00]);
  }

 private:
  double cosines_[8][8];
};

void Marker(std::vector<uint8_t>* out, uint8_t marker) {
  out->push_back(0xFF);
  out->push_back(marker);
}

void Word(std::vector<uint8_t>* out, size_t value) {
  out->push_back(static_cast<uint8_t>(value >> 8));
  out->push_back(static_cast<uint8_t>(value));
}

void HuffmanSegment(std::vector<uint8_t>* out, uint8_t table_class_and_id,
                    const uint8_t bits[16], const uint8_t* values, size_t count) {
  Marker(out, 0xC4);
  Word(out, 2 + 1 + 16 + count);
  out->push_back(table_class_and_id);
  out->insert(out->end(), bits, bits + 16);
  out->insert(out->end(), values, values + count);
}

}  // namespace

std::vector<uint8_t> EncodeJpeg(const uint8_t* bgra, size_t width, size_t height,
                                size_t stride, int quality) {
  quality = std::clamp(quality, 1, 100);
  uint8_t luma_quant[64];
  uint8_t chroma_quant[64];
  ScaleQuant(kLumaQuant, quality, luma_quant);
  ScaleQuant(kChromaQuant, quality, chroma_quant);

  std::vector<uint8_t> out;
  out.reserve(width * height / 4 + 1024);
  Marker(&out, 0xD8);  // SOI

  // APP0: JFIF 1.1, no density, no thumbnail.
  Marker(&out, 0xE0);
  Word(&out, 16);
  for (const char c : {'J', 'F', 'I', 'F', '\0'}) out.push_back(static_cast<uint8_t>(c));
  for (const uint8_t b : {1, 1, 0, 0, 1, 0, 1, 0, 0}) out.push_back(b);

  // DQT: both tables, in zig-zag order.
  Marker(&out, 0xDB);
  Word(&out, 2 + 2 * 65);
  out.push_back(0);
  for (int i = 0; i < 64; ++i) out.push_back(luma_quant[kZigzag[i]]);
  out.push_back(1);
  for (int i = 0; i < 64; ++i) out.push_back(chroma_quant[kZigzag[i]]);

  // SOF0: 8 bits, three components, none subsampled.
  Marker(&out, 0xC0);
  Word(&out, 17);
  out.push_back(8);
  Word(&out, height);
  Word(&out, width);
  out.push_back(3);
  for (const uint8_t component : {1, 2, 3}) {
    out.push_back(component);
    out.push_back(0x11);
    out.push_back(component == 1 ? 0 : 1);
  }

  HuffmanSegment(&out, 0x00, kLumaDcBits, kDcValues, sizeof(kDcValues));
  HuffmanSegment(&out, 0x10, kLumaAcBits, kLumaAcValues, sizeof(kLumaAcValues));
  HuffmanSegment(&out, 0x01, kChromaDcBits, kDcValues, sizeof(kDcValues));
  HuffmanSegment(&out, 0x11, kChromaAcBits, kChromaAcValues, sizeof(kChromaAcValues));

  // SOS: the three components, luma tables for Y, chroma for Cb and Cr.
  Marker(&out, 0xDA);
  Word(&out, 12);
  out.push_back(3);
  for (const uint8_t component : {1, 2, 3}) {
    out.push_back(component);
    out.push_back(component == 1 ? 0x00 : 0x11);
  }
  out.push_back(0);
  out.push_back(63);
  out.push_back(0);

  const HuffmanTable luma_dc = BuildTable(kLumaDcBits, kDcValues);
  const HuffmanTable luma_ac = BuildTable(kLumaAcBits, kLumaAcValues);
  const HuffmanTable chroma_dc = BuildTable(kChromaDcBits, kDcValues);
  const HuffmanTable chroma_ac = BuildTable(kChromaAcBits, kChromaAcValues);
  const BlockEncoder encoder;
  BitWriter writer(&out);
  int dc_y = 0;
  int dc_cb = 0;
  int dc_cr = 0;
  float y_block[64];
  float cb_block[64];
  float cr_block[64];
  for (size_t block_y = 0; block_y < height; block_y += 8) {
    for (size_t block_x = 0; block_x < width; block_x += 8) {
      for (int y = 0; y < 8; ++y) {
        // Past the edge, the last row and column repeat.
        const size_t row = std::min(block_y + y, height - 1);
        for (int x = 0; x < 8; ++x) {
          const size_t column = std::min(block_x + x, width - 1);
          const uint8_t* pixel = bgra + row * stride + column * 4;
          const float b = pixel[0];
          const float g = pixel[1];
          const float r = pixel[2];
          // JFIF's full-range YCbCr, level shifted by 128.
          y_block[y * 8 + x] = 0.299f * r + 0.587f * g + 0.114f * b - 128;
          cb_block[y * 8 + x] = -0.168736f * r - 0.331264f * g + 0.5f * b;
          cr_block[y * 8 + x] = 0.5f * r - 0.418688f * g - 0.081312f * b;
        }
      }
      encoder.Encode(y_block, luma_quant, luma_dc, luma_ac, &dc_y, &writer);
      encoder.Encode(cb_block, chroma_quant, chroma_dc, chroma_ac, &dc_cb, &writer);
      encoder.Encode(cr_block, chroma_quant, chroma_dc, chroma_ac, &dc_cr, &writer);
    }
  }
  writer.Finish();
  Marker(&out, 0xD9);  // EOI
  return out;
}

}  // namespace raccoon
