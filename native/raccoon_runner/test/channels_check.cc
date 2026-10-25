// raccoon_channels_check: the channels the runner answers itself, fed
// random and broken input from a fixed seed. Fails on a crash, an
// exception, a reply the app could not read, or a text field whose
// selection or composing range leaves its text. Prints one line; exits 0
// on a pass. Run by the runtime's integration tests; not shipped.
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "secure_storage_options.h"
#include "standard_codec.h"
#include "text_input.h"
#include "window_channels.h"

using raccoon::CodecValue;
using json = nlohmann::json;

namespace {

std::mt19937 rng(20261025);

int Fail(const std::string& why) {
  std::printf("CHANNELS failed: %s\n", why.c_str());
  return 1;
}

// A value of every codec type, nested a little.
CodecValue RandomValue(int depth) {
  static const char* keys[] = {"width", "height", "title", "options", "key", "value",
                               "devicePixelRatio", "fullscreen"};
  switch (rng() % (depth > 2 ? 4 : 6)) {
    case 0: return CodecValue();
    case 1: return CodecValue::Double(static_cast<double>(static_cast<int>(rng())) / 7);
    case 2: return CodecValue::String(std::string(rng() % 5, 'k'));
    case 3: return CodecValue::Bool(rng() % 2 == 0);
    case 4: {
      std::vector<CodecValue> items;
      for (int i = rng() % 4; i > 0; --i) items.push_back(RandomValue(depth + 1));
      return CodecValue::List(std::move(items));
    }
    default: {
      std::vector<std::pair<std::string, CodecValue>> items;
      for (int i = rng() % 4; i > 0; --i) items.emplace_back(keys[rng() % 8], RandomValue(depth + 1));
      return CodecValue::Map(std::move(items));
    }
  }
}

// Bytes that are an encoding, then broken a little, or noise.
std::vector<uint8_t> Mangle(std::vector<uint8_t> data) {
  if (rng() % 3 == 0) {
    for (int k = 0; k < 3 && !data.empty(); ++k) data[rng() % data.size()] = static_cast<uint8_t>(rng());
  }
  if (rng() % 5 == 0 && !data.empty()) data.resize(rng() % data.size());
  return data;
}

// Letters, emoji (surrogate pairs), stray bytes and encoded lone surrogates.
std::string RandomText() {
  std::string text;
  for (int i = rng() % 12; i > 0; --i) {
    switch (rng() % 4) {
      case 0: text += static_cast<char>('a' + rng() % 26); break;
      case 1: text += "\xF0\x9F\x98\x80"; break;
      case 2: text += static_cast<char>(rng()); break;
      default: text += "\xED\xA0\x80"; break;
    }
  }
  return text;
}

int Position() { return static_cast<int>(rng() % 30) - 5; }

int CheckCodec() {
  for (int i = 0; i < 100000; ++i) {
    std::vector<uint8_t> data;
    if (i % 2 == 0) {
      data.resize(rng() % 64);
      for (auto& byte : data) byte = static_cast<uint8_t>(rng());
    } else {
      data = Mangle(raccoon::EncodeMethodCall("m", RandomValue(0)));
    }
    CodecValue value;
    raccoon::DecodeValue(data.data(), data.size(), &value);
    raccoon::MethodCall call;
    raccoon::DecodeMethodCall(data.data(), data.size(), &call);
  }
  return 0;
}

int CheckWindowChannels() {
  static const char* channels[] = {"desktop_window", "window_manager", "flutter/windowsize",
                                   "dev.leanflutter.plugins/screen_retriever", "screen_retriever",
                                   "dev.leanflutter.plugins/screen_retriever_event"};
  static const char* methods[] = {"getWindowSize", "setMinWindowSize", "getBounds", "setTitle",
                                  "getWindowInfo", "setWindowMinimumSize", "getPrimaryDisplay",
                                  "getAllDisplays", "getCursorScreenPoint", "listen", "write", "read"};
  raccoon::WindowChannels windows;
  windows.SetViewSize(800, 600, 2.0);
  for (int i = 0; i < 30000; ++i) {
    const std::vector<uint8_t> data =
        Mangle(raccoon::EncodeMethodCall(methods[rng() % 12], RandomValue(0)));
    std::vector<uint8_t> reply;
    windows.Handle(channels[rng() % 6], data.data(), data.size(), &reply);
    std::vector<uint8_t> rewritten;
    raccoon::RewriteSecureStorageCall("plugins.it_nomads.com/flutter_secure_storage", data.data(),
                                      data.size(), &rewritten);
  }
  return 0;
}

int CheckTextInput() {
  static const uint64_t keys[] = {0x100000008, 0x10000007f, 0x100000302, 0x100000303,
                                  0x100000301, 0x100000304, 0x100000305, 0x100000306,
                                  0x10000000d, 0x61, 0x68, 0x64};
  for (int session = 0; session < 2000; ++session) {
    raccoon::TextInput input;
    input.SetComposer(rng() % 2 == 0);
    bool unreadable = false;
    input.SetSender([&unreadable](const std::string&, const std::string& body) {
      if (json::parse(body, nullptr, false).is_discarded()) unreadable = true;
    });
    auto call = [&input](const json& message) {
      const std::string text = message.dump(-1, ' ', false, json::error_handler_t::replace);
      std::vector<uint8_t> reply;
      input.Handle("flutter/textinput", reinterpret_cast<const uint8_t*>(text.data()), text.size(),
                   &reply);
    };
    call({{"method", "TextInput.setClient"},
          {"args", json::array({1, {{"inputType", {{"name", rng() % 2 ? "TextInputType.multiline"
                                                                     : "TextInputType.text"}}},
                                    {"inputAction", "TextInputAction.newline"},
                                    {"enableDeltaModel", rng() % 2 == 0}}})}});
    for (int step = 0; step < 20; ++step) {
      switch (rng() % 3) {
        case 0:
          call({{"method", "TextInput.setEditingState"},
                {"args", {{"text", RandomText()}, {"selectionBase", Position()},
                          {"selectionExtent", Position()}, {"composingBase", Position()},
                          {"composingExtent", Position()}}}});
          break;
        case 1:
          input.HandleKey(keys[rng() % 12], rng() % 3 ? RandomText().substr(0, 4) : "",
                          rng() % 2 == 0, rng() % 2 == 0, rng() % 2 == 0, rng() % 2 == 0);
          break;
        default:
          input.ApplyEditing(RandomText(), Position(), Position(), Position(), Position());
      }
      if (unreadable) return Fail("the text field sent a message that is not JSON");
      const raccoon::TextFieldState state = input.state();
      const int size = static_cast<int>(input.text().size());
      if (input.selection_base() < 0 || input.selection_base() > size ||
          input.selection_extent() < 0 || input.selection_extent() > size) {
        return Fail("a selection outside the text");
      }
      if (state.composing_base != -1 &&
          (state.composing_base < 0 || state.composing_extent > size ||
           state.composing_base > state.composing_extent)) {
        return Fail("a composing range outside the text");
      }
    }
  }
  return 0;
}

}  // namespace

int main() {
  try {
    if (CheckCodec() != 0 || CheckWindowChannels() != 0 || CheckTextInput() != 0) return 1;
  } catch (const std::exception& error) {
    return Fail(std::string("an exception: ") + error.what());
  }
  std::printf("CHANNELS ok: the codec, the window channels and the text field held\n");
  return 0;
}
