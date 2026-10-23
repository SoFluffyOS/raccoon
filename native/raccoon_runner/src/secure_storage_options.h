#pragma once
// flutter_secure_storage on macOS asks the Keychain for the data protection
// keychain by default, and for an access group or iCloud sync when the app
// says so. Each needs an entitlement a signed app carries; the runner's
// bundle is unsigned, so the Keychain answers -34018 (#87). The runner
// rewrites those options on the way to the plugin: the login keychain, no
// access group, no sync. Same plugin, real Keychain, no entitlement.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace raccoon {

// The call with its options rewritten into |out|; false when |channel| is
// not the plugin's or the bytes are not a call with arguments to rewrite.
bool RewriteSecureStorageCall(const std::string& channel, const uint8_t* data, size_t size,
                              std::vector<uint8_t>* out);

}  // namespace raccoon
