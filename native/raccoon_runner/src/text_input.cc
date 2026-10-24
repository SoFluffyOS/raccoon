#include "text_input.h"

#include <algorithm>

#include <nlohmann/json.hpp>

namespace raccoon {
namespace {

using json = nlohmann::json;

// Flutter's logical key ids (LogicalKeyboardKey.keyId).
constexpr uint64_t kBackspace = 0x100000008;
constexpr uint64_t kTab = 0x100000009;
constexpr uint64_t kEnter = 0x10000000d;
constexpr uint64_t kEscape = 0x10000001b;
constexpr uint64_t kDelete = 0x10000007f;
constexpr uint64_t kArrowLeft = 0x100000302;
constexpr uint64_t kArrowRight = 0x100000303;
constexpr uint64_t kEnd = 0x100000305;
constexpr uint64_t kHome = 0x100000306;
constexpr uint64_t kNumpadEnter = 0x20000020d;

bool IsHighSurrogate(char16_t c) { return c >= 0xD800 && c <= 0xDBFF; }
bool IsLowSurrogate(char16_t c) { return c >= 0xDC00 && c <= 0xDFFF; }

std::u16string ToUtf16(const std::string& utf8) {
  std::u16string out;
  for (size_t i = 0; i < utf8.size();) {
    const unsigned char c = utf8[i];
    uint32_t code = 0;
    size_t length = 1;
    if (c < 0x80) {
      code = c;
    } else if ((c & 0xE0) == 0xC0) {
      code = c & 0x1F;
      length = 2;
    } else if ((c & 0xF0) == 0xE0) {
      code = c & 0x0F;
      length = 3;
    } else if ((c & 0xF8) == 0xF0) {
      code = c & 0x07;
      length = 4;
    } else {
      ++i;
      continue;
    }
    if (i + length > utf8.size()) break;
    for (size_t k = 1; k < length; ++k) {
      code = (code << 6) | (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
    }
    i += length;
    if (code > 0x10FFFF) code = 0xFFFD;
    if (code >= 0x10000) {
      code -= 0x10000;
      out.push_back(static_cast<char16_t>(0xD800 + (code >> 10)));
      out.push_back(static_cast<char16_t>(0xDC00 + (code & 0x3FF)));
    } else {
      out.push_back(static_cast<char16_t>(code));
    }
  }
  return out;
}

std::string ToUtf8(const std::u16string& utf16) {
  std::string out;
  for (size_t i = 0; i < utf16.size(); ++i) {
    uint32_t code = utf16[i];
    if (IsHighSurrogate(utf16[i]) && i + 1 < utf16.size() &&
        IsLowSurrogate(utf16[i + 1])) {
      code = 0x10000 + ((code - 0xD800) << 10) + (utf16[i + 1] - 0xDC00);
      ++i;
    } else if (IsHighSurrogate(utf16[i]) || IsLowSurrogate(utf16[i])) {
      code = 0xFFFD;
    }
    if (code < 0x80) {
      out.push_back(static_cast<char>(code));
    } else if (code < 0x800) {
      out.push_back(static_cast<char>(0xC0 | (code >> 6)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else if (code < 0x10000) {
      out.push_back(static_cast<char>(0xE0 | (code >> 12)));
      out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else {
      out.push_back(static_cast<char>(0xF0 | (code >> 18)));
      out.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    }
  }
  return out;
}

std::string Str(const json& object, const char* key, const std::string& fallback) {
  if (!object.is_object() || !object.contains(key)) return fallback;
  const json& value = object[key];
  return value.is_string() ? value.get<std::string>() : fallback;
}

int Int(const json& object, const char* key, int fallback) {
  if (!object.is_object() || !object.contains(key)) return fallback;
  const json& value = object[key];
  return value.is_number_integer() ? value.get<int>() : fallback;
}

// Invalid UTF-8 from the app becomes U+FFFD rather than an exception on the
// platform thread.
std::string Dump(const json& value) {
  return value.dump(-1, ' ', false, json::error_handler_t::replace);
}

bool Flag(const json& object, const char* key) {
  if (!object.is_object() || !object.contains(key)) return false;
  const json& value = object[key];
  return value.is_boolean() && value.get<bool>();
}

#if defined(__APPLE__)
constexpr uint64_t kArrowDown = 0x100000301;
constexpr uint64_t kArrowUp = 0x100000304;
constexpr uint64_t kPageDown = 0x100000307;
constexpr uint64_t kPageUp = 0x100000308;

// What AppKit's standard key bindings make of a key in a text field, which a
// Mac app's framework leaves unhandled and waits for as performSelectors.
std::vector<const char*> MacSelectors(uint64_t logical, bool shift,
                                      bool control, bool alt, bool meta) {
  const bool line = meta || control;
  switch (logical) {
    case kArrowLeft:
      if (alt) {
        return {shift ? "moveWordLeftAndModifySelection:" : "moveWordLeft:"};
      }
      if (line) {
        return {shift ? "moveToLeftEndOfLineAndModifySelection:"
                      : "moveToLeftEndOfLine:"};
      }
      return {shift ? "moveLeftAndModifySelection:" : "moveLeft:"};
    case kArrowRight:
      if (alt) {
        return {shift ? "moveWordRightAndModifySelection:" : "moveWordRight:"};
      }
      if (line) {
        return {shift ? "moveToRightEndOfLineAndModifySelection:"
                      : "moveToRightEndOfLine:"};
      }
      return {shift ? "moveRightAndModifySelection:" : "moveRight:"};
    case kArrowUp:
      if (shift && alt) return {"moveParagraphBackwardAndModifySelection:"};
      if (alt) return {"moveBackward:", "moveToBeginningOfParagraph:"};
      if (meta) {
        return {shift ? "moveToBeginningOfDocumentAndModifySelection:"
                      : "moveToBeginningOfDocument:"};
      }
      return {shift ? "moveUpAndModifySelection:" : "moveUp:"};
    case kArrowDown:
      if (shift && alt) return {"moveParagraphForwardAndModifySelection:"};
      if (alt) return {"moveForward:", "moveToEndOfParagraph:"};
      if (meta) {
        return {shift ? "moveToEndOfDocumentAndModifySelection:"
                      : "moveToEndOfDocument:"};
      }
      return {shift ? "moveDownAndModifySelection:" : "moveDown:"};
    case kHome:
      return {shift ? "moveToBeginningOfDocumentAndModifySelection:"
                    : "scrollToBeginningOfDocument:"};
    case kEnd:
      return {shift ? "moveToEndOfDocumentAndModifySelection:"
                    : "scrollToEndOfDocument:"};
    case kPageUp:
      return {shift ? "pageUpAndModifySelection:" : "scrollPageUp:"};
    case kPageDown:
      return {shift ? "pageDownAndModifySelection:" : "scrollPageDown:"};
    case kBackspace:
      if (alt) return {"deleteWordBackward:"};
      if (meta) return {"deleteToBeginningOfLine:"};
      return {"deleteBackward:"};
    case kDelete:
      if (alt) return {"deleteWordForward:"};
      return {"deleteForward:"};
    case kTab:
      return {shift ? "insertBacktab:" : "insertTab:"};
    case kEscape:
      return {"cancelOperation:"};
    default:
      return {};
  }
}
#endif

}  // namespace

bool TextInput::Handle(const std::string& channel, const uint8_t* data,
                       size_t size, std::vector<uint8_t>* reply) {
  if (channel != "flutter/textinput") return false;
  // Every TextInput.* call succeeds with no result; the ones the model does
  // not need (show, hide, sizes, styles, autofill) are no-ops.
  static const std::string kNullResult = "[null]";
  reply->assign(kNullResult.begin(), kNullResult.end());
  const json call = json::parse(data, data + size, nullptr, false);
  if (!call.is_object()) return true;
  const std::string method = Str(call, "method", "");
  const json args = call.contains("args") ? call["args"] : json();
  if (method == "TextInput.setClient") {
    SetClient(args);
    Changed();
  } else if (method == "TextInput.updateConfig") {
    ApplyConfig(args);
    Changed();
  } else if (method == "TextInput.setEditingState") {
    SetEditingState(args);
    Changed();
  } else if (method == "TextInput.clearClient") {
    client_id_ = -1;
    Changed();
  }
  return true;
}

void TextInput::SetClient(const json& args) {
  if (!args.is_array() || args.size() < 2 || !args[0].is_number_integer()) {
    return;
  }
  client_id_ = args[0].get<int>();
  ApplyConfig(args[1]);
  text_.clear();
  base_ = extent_ = 0;
  composing_base_ = composing_extent_ = -1;
}

void TextInput::ApplyConfig(const json& config) {
  const json type = config.is_object() && config.contains("inputType")
                        ? config["inputType"]
                        : json();
  multiline_ = Str(type, "name", "") == "TextInputType.multiline";
  input_action_ = Str(config, "inputAction", "TextInputAction.done");
  delta_model_ = Flag(config, "enableDeltaModel");
  obscure_ = Flag(config, "obscureText");
}

void TextInput::SetEditingState(const json& state) {
  SetState(ToUtf16(Str(state, "text", "")), Int(state, "selectionBase", -1),
           Int(state, "selectionExtent", -1), Int(state, "composingBase", -1),
           Int(state, "composingExtent", -1));
}

void TextInput::SetState(std::u16string text, int selection_base,
                         int selection_extent, int composing_base,
                         int composing_extent) {
  text_ = std::move(text);
  const int size = static_cast<int>(text_.size());
  // Positions land on whole characters, so no edit splits a surrogate pair.
  auto clamp = [this, size](int value) {
    if (value < 0 || value > size) return size;
    if (value > 0 && value < size && IsLowSurrogate(text_[value]) &&
        IsHighSurrogate(text_[value - 1])) {
      return value - 1;
    }
    return value;
  };
  base_ = clamp(selection_base);
  extent_ = clamp(selection_extent);
  const bool composing = composing_base >= 0 &&
                         composing_base <= composing_extent &&
                         composing_extent <= size;
  composing_base_ = composing ? composing_base : -1;
  composing_extent_ = composing ? composing_extent : -1;
}

bool TextInput::HandleKey(uint64_t logical, const std::string& character,
                          bool shift, bool control, bool alt, bool meta) {
  if (client_id_ < 0) return false;
#if defined(__APPLE__)
  const auto selectors = MacSelectors(logical, shift, control, alt, meta);
  if (!selectors.empty()) {
    PerformSelectors(selectors);
    return true;
  }
#endif
  // Shortcuts belong to the framework; a key with those held types nothing,
  // but Option and AltGr (Ctrl+Alt on Windows) pick characters.
  if (meta || (control && !alt)) return false;
  if (alt) return TypeCharacter(character);
  const std::u16string before = text_;
  switch (logical) {
    case kBackspace: Backspace(); break;
    case kDelete: Delete(); break;
    case kArrowLeft: Move(-1, shift); break;
    case kArrowRight: Move(1, shift); break;
    case kHome: MoveTo(0, shift); break;
    case kEnd: MoveTo(static_cast<int>(text_.size()), shift); break;
    case kEnter:
    case kNumpadEnter:
      // As desktop embedders do: a newline only where the field asks for
      // one, and the action every time.
      if (multiline_ && input_action_ == "TextInputAction.newline") {
        AddText(u"\n");
        SendEditingState(before);
        Changed();
      }
      PerformAction();
      return true;
    case kTab:
    case kEscape:
      return false;
    default:
      return TypeCharacter(character);
  }
  SendEditingState(before);
  Changed();
  return true;
}

bool TextInput::TypeCharacter(const std::string& character) {
  // A composing client types through its input method, which brings the
  // characters by ApplyEditing.
  if (composer_ || character.empty()) return false;
  const unsigned char first = character[0];
  if (first < 0x20 || first == 0x7F) return false;
  const std::u16string before = text_;
  AddText(ToUtf16(character));
  SendEditingState(before);
  Changed();
  return true;
}

void TextInput::ApplyEditing(const std::string& text, int selection_base,
                             int selection_extent, int composing_base,
                             int composing_extent) {
  if (client_id_ < 0) return;
  const std::u16string before = text_;
  SetState(ToUtf16(text), selection_base, selection_extent, composing_base,
           composing_extent);
  SendEditingState(before);
  Changed();
}

TextFieldState TextInput::state() const {
  TextFieldState state;
  state.active = client_id_ >= 0;
  state.text = ToUtf8(text_);
  state.selection_base = base_;
  state.selection_extent = extent_;
  state.composing_base = composing_base_;
  state.composing_extent = composing_extent_;
  state.multiline = multiline_;
  state.input_action = input_action_;
  state.obscure = obscure_;
  return state;
}

void TextInput::Changed() {
  if (listener_) listener_(state());
}

void TextInput::DeleteSelection() {
  const int low = std::min(base_, extent_);
  const int high = std::max(base_, extent_);
  text_.erase(low, high - low);
  base_ = extent_ = low;
  composing_base_ = composing_extent_ = -1;
}

void TextInput::AddText(const std::u16string& text) {
  if (base_ != extent_) DeleteSelection();
  text_.insert(base_, text);
  base_ = extent_ = base_ + static_cast<int>(text.size());
  composing_base_ = composing_extent_ = -1;
}

void TextInput::Backspace() {
  if (base_ != extent_) {
    DeleteSelection();
    return;
  }
  if (base_ == 0) return;
  int count = 1;
  if (base_ >= 2 && IsLowSurrogate(text_[base_ - 1]) &&
      IsHighSurrogate(text_[base_ - 2])) {
    count = 2;
  }
  text_.erase(base_ - count, count);
  base_ = extent_ = base_ - count;
  composing_base_ = composing_extent_ = -1;
}

void TextInput::Delete() {
  if (base_ != extent_) {
    DeleteSelection();
    return;
  }
  const int size = static_cast<int>(text_.size());
  if (base_ >= size) return;
  int count = 1;
  if (base_ + 1 < size && IsHighSurrogate(text_[base_]) &&
      IsLowSurrogate(text_[base_ + 1])) {
    count = 2;
  }
  text_.erase(base_, count);
  composing_base_ = composing_extent_ = -1;
}

void TextInput::Move(int direction, bool select) {
  const int size = static_cast<int>(text_.size());
  if (!select && base_ != extent_) {
    // A plain arrow collapses a selection to its edge.
    base_ = extent_ = direction < 0 ? std::min(base_, extent_)
                                    : std::max(base_, extent_);
    return;
  }
  int next = extent_ + direction;
  if (direction < 0 && extent_ >= 2 && IsLowSurrogate(text_[extent_ - 1]) &&
      IsHighSurrogate(text_[extent_ - 2])) {
    next = extent_ - 2;
  }
  if (direction > 0 && extent_ + 1 < size && IsHighSurrogate(text_[extent_]) &&
      IsLowSurrogate(text_[extent_ + 1])) {
    next = extent_ + 2;
  }
  MoveTo(std::clamp(next, 0, size), select);
}

void TextInput::MoveTo(int position, bool select) {
  extent_ = position;
  if (!select) base_ = position;
}

void TextInput::SendEditingState(const std::u16string& before) {
  if (!sender_) return;
  json state = {
      {"selectionBase", base_},
      {"selectionExtent", extent_},
      {"selectionAffinity", "TextAffinity.downstream"},
      {"selectionIsDirectional", false},
      {"composingBase", composing_base_},
      {"composingExtent", composing_extent_},
  };
  json call;
  if (delta_model_) {
    // One replacement delta covering the whole text keeps the framework's
    // copy exact without tracking the edit itself.
    json delta = state;
    delta["oldText"] = ToUtf8(before);
    delta["deltaText"] = ToUtf8(text_);
    delta["deltaStart"] = 0;
    delta["deltaEnd"] = static_cast<int>(before.size());
    call = {{"method", "TextInputClient.updateEditingStateWithDeltas"},
            {"args", json::array({client_id_,
                                  json{{"deltas", json::array({delta})}}})}};
  } else {
    state["text"] = ToUtf8(text_);
    call = {{"method", "TextInputClient.updateEditingState"},
            {"args", json::array({client_id_, state})}};
  }
  sender_("flutter/textinput", Dump(call));
}

void TextInput::PerformAction() {
  if (!sender_) return;
  const json call = {{"method", "TextInputClient.performAction"},
                     {"args", json::array({client_id_, input_action_})}};
  sender_("flutter/textinput", Dump(call));
}

void TextInput::PerformSelectors(const std::vector<const char*>& selectors) {
  if (!sender_) return;
  const json call = {
      {"method", "TextInputClient.performSelectors"},
      {"args", json::array({client_id_, json(selectors)})}};
  sender_("flutter/textinput", Dump(call));
}

}  // namespace raccoon
