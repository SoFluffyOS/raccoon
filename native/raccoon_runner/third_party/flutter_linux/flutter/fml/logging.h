#pragma once
// Raccoon's stand-in for the engine's logging header: the vendored sources
// log through FML_LOG; here that is a GLib log line.
#include <glib.h>

#include <sstream>
#include <string>

namespace fml {

class LogMessage {
 public:
  explicit LogMessage(const char* severity) : severity_(severity) {}
  ~LogMessage() {
    const GLogLevelFlags level = severity_ == "ERROR" || severity_ == "FATAL"
                                     ? G_LOG_LEVEL_WARNING
                                     : G_LOG_LEVEL_MESSAGE;
    g_log("flutter", level, "%s", stream_.str().c_str());
  }
  std::ostream& stream() { return stream_; }

 private:
  std::string severity_;
  std::ostringstream stream_;
};

}  // namespace fml

#define FML_LOG(severity) ::fml::LogMessage(#severity).stream()
#define FML_DLOG(severity) FML_LOG(severity)
#define FML_CHECK(condition) \
  if (!(condition)) ::fml::LogMessage("FATAL").stream() << "Check failed: " #condition ". "
#define FML_DCHECK(condition) FML_CHECK(condition)
