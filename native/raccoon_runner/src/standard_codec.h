#pragma once

// Flutter's StandardMessageCodec and StandardMethodCodec, the subset the
// runner needs to answer method channels itself: null, booleans, integers,
// doubles, strings, lists and maps. Typed data lists decode into plain lists.

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace raccoon {

class CodecValue {
 public:
  enum class Type { kNull, kBool, kInt, kDouble, kString, kList, kMap };

  CodecValue() = default;
  static CodecValue Bool(bool value);
  static CodecValue Int(int64_t value);
  static CodecValue Double(double value);
  static CodecValue String(std::string value);
  static CodecValue List(std::vector<CodecValue> items);
  // A map from string keys, the shape plugins use for arguments and results.
  static CodecValue Map(
      std::vector<std::pair<std::string, CodecValue>> entries);

  Type type() const { return type_; }
  bool is_null() const { return type_ == Type::kNull; }
  bool bool_value() const { return bool_; }
  int64_t int_value() const { return int_; }
  double double_value() const { return double_; }
  const std::string& string_value() const { return string_; }
  // A list's items; for a map, keys and values alternate.
  const std::vector<CodecValue>& items() const { return items_; }

  // A number as a double, whichever way it was encoded; |fallback| otherwise.
  double AsDouble(double fallback) const;
  // The value under a string key of a map, or null.
  const CodecValue& Get(const std::string& key) const;

 private:
  Type type_ = Type::kNull;
  bool bool_ = false;
  int64_t int_ = 0;
  double double_ = 0;
  std::string string_;
  std::vector<CodecValue> items_;
};

struct MethodCall {
  std::string method;
  CodecValue arguments;
};

// Decodes a StandardMethodCodec call; false when the bytes are not one.
bool DecodeMethodCall(const uint8_t* data, size_t size, MethodCall* call);

// One StandardMessageCodec value, the whole message; false when the bytes
// are not one. Pigeon's own types (type bytes from 128) decode as the list or
// number they wrap.
bool DecodeValue(const uint8_t* data, size_t size, CodecValue* value);
std::vector<uint8_t> EncodeValue(const CodecValue& value);

// The StandardMethodCodec envelopes.
std::vector<uint8_t> EncodeSuccess(const CodecValue& result);
std::vector<uint8_t> EncodeError(const std::string& code,
                                 const std::string& message);

}  // namespace raccoon
