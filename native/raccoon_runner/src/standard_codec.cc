#include "standard_codec.h"

#include <cstring>

namespace raccoon {

namespace {

// StandardMessageCodec's type bytes.
enum : uint8_t {
  kNull = 0,
  kTrue = 1,
  kFalse = 2,
  kInt32 = 3,
  kInt64 = 4,
  kLargeInt = 5,
  kFloat64 = 6,
  kString = 7,
  kUint8List = 8,
  kInt32List = 9,
  kInt64List = 10,
  kFloat64List = 11,
  kList = 12,
  kMap = 13,
  kFloat32List = 14,
};

// Reads a buffer the way ReadBuffer does: little endian, with alignment
// counted from the start of the message.
class Reader {
 public:
  Reader(const uint8_t* data, size_t size) : data_(data), size_(size) {}

  bool done() const { return pos_ == size_; }

  bool Byte(uint8_t* out) { return Bytes(out, 1); }

  bool Bytes(void* out, size_t count) {
    if (count > size_ - pos_) return false;
    if (count > 0) std::memcpy(out, data_ + pos_, count);
    pos_ += count;
    return true;
  }

  bool Align(size_t alignment) {
    const size_t mod = pos_ % alignment;
    if (mod == 0) return true;
    const size_t skip = alignment - mod;
    if (skip > size_ - pos_) return false;
    pos_ += skip;
    return true;
  }

  bool Size(size_t* out) {
    uint8_t first = 0;
    if (!Byte(&first)) return false;
    if (first < 254) {
      *out = first;
      return true;
    }
    if (first == 254) {
      uint16_t value = 0;
      if (!Bytes(&value, sizeof(value))) return false;
      *out = value;
      return true;
    }
    uint32_t value = 0;
    if (!Bytes(&value, sizeof(value))) return false;
    *out = value;
    return true;
  }

  size_t remaining() const { return size_ - pos_; }

 private:
  const uint8_t* data_;
  size_t size_;
  size_t pos_ = 0;
};

template <typename T>
bool ReadTypedList(Reader* reader, std::vector<CodecValue>* items, bool as_double) {
  size_t length = 0;
  if (!reader->Size(&length)) return false;
  if (sizeof(T) > 1 && !reader->Align(sizeof(T))) return false;
  if (length > reader->remaining() / sizeof(T)) return false;
  items->reserve(length);
  for (size_t i = 0; i < length; ++i) {
    T element{};
    if (!reader->Bytes(&element, sizeof(T))) return false;
    items->push_back(as_double ? CodecValue::Double(static_cast<double>(element))
                               : CodecValue::Int(static_cast<int64_t>(element)));
  }
  return true;
}

bool ReadValue(Reader* reader, CodecValue* out, int depth);

bool ReadItems(Reader* reader, size_t count, std::vector<CodecValue>* items,
               int depth) {
  // Each item takes at least one byte; a count beyond that is corrupt.
  if (count > reader->remaining()) return false;
  items->reserve(count);
  for (size_t i = 0; i < count; ++i) {
    CodecValue item;
    if (!ReadValue(reader, &item, depth + 1)) return false;
    items->push_back(std::move(item));
  }
  return true;
}

bool ReadValue(Reader* reader, CodecValue* out, int depth) {
  if (depth > 64) return false;
  uint8_t type = 0;
  if (!reader->Byte(&type)) return false;
  switch (type) {
    case kNull:
      *out = CodecValue();
      return true;
    case kTrue:
    case kFalse:
      *out = CodecValue::Bool(type == kTrue);
      return true;
    case kInt32: {
      int32_t value = 0;
      if (!reader->Bytes(&value, sizeof(value))) return false;
      *out = CodecValue::Int(value);
      return true;
    }
    case kInt64: {
      int64_t value = 0;
      if (!reader->Bytes(&value, sizeof(value))) return false;
      *out = CodecValue::Int(value);
      return true;
    }
    case kFloat64: {
      double value = 0;
      if (!reader->Align(8) || !reader->Bytes(&value, sizeof(value))) return false;
      *out = CodecValue::Double(value);
      return true;
    }
    case kLargeInt:
    case kString: {
      size_t length = 0;
      if (!reader->Size(&length) || length > reader->remaining()) return false;
      std::string text(length, '\0');
      if (!reader->Bytes(text.data(), length)) return false;
      *out = CodecValue::String(std::move(text));
      return true;
    }
    case kUint8List: {
      std::vector<CodecValue> items;
      if (!ReadTypedList<uint8_t>(reader, &items, false)) return false;
      *out = CodecValue::List(std::move(items));
      return true;
    }
    case kInt32List: {
      std::vector<CodecValue> items;
      if (!ReadTypedList<int32_t>(reader, &items, false)) return false;
      *out = CodecValue::List(std::move(items));
      return true;
    }
    case kInt64List: {
      std::vector<CodecValue> items;
      if (!ReadTypedList<int64_t>(reader, &items, false)) return false;
      *out = CodecValue::List(std::move(items));
      return true;
    }
    case kFloat32List: {
      std::vector<CodecValue> items;
      if (!ReadTypedList<float>(reader, &items, true)) return false;
      *out = CodecValue::List(std::move(items));
      return true;
    }
    case kFloat64List: {
      std::vector<CodecValue> items;
      if (!ReadTypedList<double>(reader, &items, true)) return false;
      *out = CodecValue::List(std::move(items));
      return true;
    }
    case kList: {
      size_t count = 0;
      std::vector<CodecValue> items;
      if (!reader->Size(&count) || !ReadItems(reader, count, &items, depth)) {
        return false;
      }
      *out = CodecValue::List(std::move(items));
      return true;
    }
    case kMap: {
      size_t count = 0;
      std::vector<CodecValue> items;
      if (!reader->Size(&count) || count > reader->remaining() ||
          !ReadItems(reader, count * 2, &items, depth)) {
        return false;
      }
      std::vector<std::pair<std::string, CodecValue>> entries;
      for (size_t i = 0; i + 1 < items.size(); i += 2) {
        // Non-string keys are kept under an empty name; no window channel
        // uses them.
        entries.emplace_back(items[i].type() == CodecValue::Type::kString
                                 ? items[i].string_value()
                                 : std::string(),
                             std::move(items[i + 1]));
      }
      *out = CodecValue::Map(std::move(entries));
      return true;
    }
    default:
      return false;
  }
}

class Writer {
 public:
  void Byte(uint8_t value) { bytes_.push_back(value); }

  void Bytes(const void* data, size_t count) {
    const auto* start = static_cast<const uint8_t*>(data);
    bytes_.insert(bytes_.end(), start, start + count);
  }

  void Align(size_t alignment) {
    while (bytes_.size() % alignment != 0) bytes_.push_back(0);
  }

  void Size(size_t value) {
    if (value < 254) {
      Byte(static_cast<uint8_t>(value));
    } else if (value <= 0xffff) {
      Byte(254);
      const uint16_t size = static_cast<uint16_t>(value);
      Bytes(&size, sizeof(size));
    } else {
      Byte(255);
      const uint32_t size = static_cast<uint32_t>(value);
      Bytes(&size, sizeof(size));
    }
  }

  void String(const std::string& text) {
    Byte(kString);
    Size(text.size());
    Bytes(text.data(), text.size());
  }

  void Value(const CodecValue& value) {
    switch (value.type()) {
      case CodecValue::Type::kNull:
        Byte(kNull);
        return;
      case CodecValue::Type::kBool:
        Byte(value.bool_value() ? kTrue : kFalse);
        return;
      case CodecValue::Type::kInt: {
        const int64_t number = value.int_value();
        if (number >= INT32_MIN && number <= INT32_MAX) {
          Byte(kInt32);
          const int32_t small = static_cast<int32_t>(number);
          Bytes(&small, sizeof(small));
        } else {
          Byte(kInt64);
          Bytes(&number, sizeof(number));
        }
        return;
      }
      case CodecValue::Type::kDouble: {
        Byte(kFloat64);
        Align(8);
        const double number = value.double_value();
        Bytes(&number, sizeof(number));
        return;
      }
      case CodecValue::Type::kString:
        String(value.string_value());
        return;
      case CodecValue::Type::kList:
        Byte(kList);
        Size(value.items().size());
        for (const CodecValue& item : value.items()) Value(item);
        return;
      case CodecValue::Type::kMap:
        Byte(kMap);
        Size(value.items().size() / 2);
        for (const CodecValue& item : value.items()) Value(item);
        return;
    }
  }

  std::vector<uint8_t> Take() { return std::move(bytes_); }

 private:
  std::vector<uint8_t> bytes_;
};

const CodecValue& NullValue() {
  static const CodecValue value;
  return value;
}

}  // namespace

CodecValue CodecValue::Bool(bool value) {
  CodecValue out;
  out.type_ = Type::kBool;
  out.bool_ = value;
  return out;
}

CodecValue CodecValue::Int(int64_t value) {
  CodecValue out;
  out.type_ = Type::kInt;
  out.int_ = value;
  return out;
}

CodecValue CodecValue::Double(double value) {
  CodecValue out;
  out.type_ = Type::kDouble;
  out.double_ = value;
  return out;
}

CodecValue CodecValue::String(std::string value) {
  CodecValue out;
  out.type_ = Type::kString;
  out.string_ = std::move(value);
  return out;
}

CodecValue CodecValue::List(std::vector<CodecValue> items) {
  CodecValue out;
  out.type_ = Type::kList;
  out.items_ = std::move(items);
  return out;
}

CodecValue CodecValue::Map(
    std::vector<std::pair<std::string, CodecValue>> entries) {
  CodecValue out;
  out.type_ = Type::kMap;
  out.items_.reserve(entries.size() * 2);
  for (auto& [key, value] : entries) {
    out.items_.push_back(String(key));
    out.items_.push_back(std::move(value));
  }
  return out;
}

double CodecValue::AsDouble(double fallback) const {
  if (type_ == Type::kDouble) return double_;
  if (type_ == Type::kInt) return static_cast<double>(int_);
  return fallback;
}

const CodecValue& CodecValue::Get(const std::string& key) const {
  if (type_ != Type::kMap) return NullValue();
  for (size_t i = 0; i + 1 < items_.size(); i += 2) {
    if (items_[i].type_ == Type::kString && items_[i].string_ == key) {
      return items_[i + 1];
    }
  }
  return NullValue();
}

bool DecodeMethodCall(const uint8_t* data, size_t size, MethodCall* call) {
  if (data == nullptr || size == 0) return false;
  Reader reader(data, size);
  CodecValue method;
  if (!ReadValue(&reader, &method, 0) ||
      method.type() != CodecValue::Type::kString) {
    return false;
  }
  call->method = method.string_value();
  call->arguments = CodecValue();
  if (!reader.done() && !ReadValue(&reader, &call->arguments, 0)) return false;
  return reader.done();
}

std::vector<uint8_t> EncodeSuccess(const CodecValue& result) {
  Writer writer;
  writer.Byte(0);
  writer.Value(result);
  return writer.Take();
}

std::vector<uint8_t> EncodeError(const std::string& code,
                                 const std::string& message) {
  Writer writer;
  writer.Byte(1);
  writer.String(code);
  writer.String(message);
  writer.Byte(kNull);
  return writer.Take();
}

}  // namespace raccoon
