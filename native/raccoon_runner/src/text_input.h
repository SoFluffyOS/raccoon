#pragma once
// The flutter/textinput channel, answered by the runner, and the editing
// model behind it. Flutter inserts typed text only through this channel: the
// framework says which field is active and what it holds, the runner applies
// the keys the framework left unhandled to its copy of the text and sends the
// new state back. Offsets are UTF-16 code units, as the framework's are.
//
// Composition (an IME) is not here yet: every key types its character.
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include <nlohmann/json_fwd.hpp>

namespace raccoon {

// The active field as a client sees it; see TextInput::SetStateListener.
struct TextFieldState {
  bool active = false;
  std::string text;  // UTF-8
  int selection_base = 0;
  int selection_extent = 0;
  int composing_base = -1;
  int composing_extent = -1;
  bool multiline = false;
  std::string input_action;
  bool obscure = false;
};

class TextInput {
 public:
  // Delivers a message to the framework on |channel|; the JSON method calls
  // the runner makes on flutter/textinput go through it.
  using Sender =
      std::function<void(const std::string& channel, const std::string& json)>;
  void SetSender(Sender sender) { sender_ = std::move(sender); }

  // Told the active field's state whenever it changes.
  using StateListener = std::function<void(const TextFieldState&)>;
  void SetStateListener(StateListener listener) {
    listener_ = std::move(listener);
  }
  TextFieldState state() const;

  // Whether the client composes text with its own input method: then keys
  // type nothing here and the field takes what ApplyEditing brings.
  void SetComposer(bool composes) { composer_ = composes; }
  bool composer() const { return composer_; }

  // The client's input method produced this value for the active field.
  void ApplyEditing(const std::string& text, int selection_base,
                    int selection_extent, int composing_base,
                    int composing_extent);

  // Answers a flutter/textinput message into |reply| and returns true;
  // returns false for any other channel.
  bool Handle(const std::string& channel, const uint8_t* data, size_t size,
              std::vector<uint8_t>* reply);

  // A key down the framework did not handle. |character| is the text the key
  // types, UTF-8, empty for keys that type nothing. Returns true when the
  // key edited the field or was consumed by it.
  bool HandleKey(uint64_t logical, const std::string& character, bool shift,
                 bool control, bool alt, bool meta);

  bool has_client() const { return client_id_ >= 0; }
  const std::u16string& text() const { return text_; }
  int selection_base() const { return base_; }
  int selection_extent() const { return extent_; }

 private:
  void SetClient(const nlohmann::json& args);
  void ApplyConfig(const nlohmann::json& config);
  void SetEditingState(const nlohmann::json& state);
  void SetState(std::u16string text, int selection_base, int selection_extent,
                int composing_base, int composing_extent);
  bool TypeCharacter(const std::string& character);
  void AddText(const std::u16string& text);
  void DeleteSelection();
  void Backspace();
  void Delete();
  void Move(int direction, bool select);
  void MoveTo(int position, bool select);
  void SendEditingState(const std::u16string& before);
  void PerformAction();
  void PerformSelectors(const std::vector<const char*>& selectors);

  void Changed();

  Sender sender_;
  StateListener listener_;
  bool composer_ = false;
  int client_id_ = -1;
  bool multiline_ = false;
  bool obscure_ = false;
  bool delta_model_ = false;
  std::string input_action_ = "TextInputAction.done";
  std::u16string text_;
  int base_ = 0;
  int extent_ = 0;
  int composing_base_ = -1;
  int composing_extent_ = -1;
};

}  // namespace raccoon
