#include "semantics_tree.h"

#include <algorithm>
#include <cmath>
#include <unordered_set>
#include <utility>

namespace raccoon {

namespace {

// Where |transform| takes (x, y), through its perspective row.
std::pair<double, double> MapPoint(const SemanticsTree::Transform& t, double x, double y) {
  const double w = t[6] * x + t[7] * y + t[8];
  const double divide = std::abs(w) < 1e-12 ? 1.0 : w;
  return {(t[0] * x + t[1] * y + t[2]) / divide, (t[3] * x + t[4] * y + t[5]) / divide};
}

}  // namespace

SemanticsTree::Transform SemanticsTree::Multiply(const Transform& a, const Transform& b) {
  Transform out{};
  for (int row = 0; row < 3; ++row) {
    for (int column = 0; column < 3; ++column) {
      double sum = 0;
      for (int k = 0; k < 3; ++k) sum += a[row * 3 + k] * b[k * 3 + column];
      out[row * 3 + column] = sum;
    }
  }
  return out;
}

void SemanticsTree::Apply(std::vector<Node> nodes) {
  for (Node& node : nodes) {
    const int32_t id = node.id;
    nodes_[id] = std::move(node);
  }
  // The framework sends no word of a node removed: its parent just stops
  // naming it.
  std::unordered_set<int32_t> reached;
  std::vector<int32_t> stack;
  if (has_root()) stack.push_back(0);
  while (!stack.empty()) {
    const int32_t id = stack.back();
    stack.pop_back();
    const auto found = nodes_.find(id);
    if (found == nodes_.end() || !reached.insert(id).second) continue;
    for (const int32_t child : found->second.children) stack.push_back(child);
  }
  for (auto it = nodes_.begin(); it != nodes_.end();) {
    it = reached.count(it->first) != 0 ? std::next(it) : nodes_.erase(it);
  }
}

std::vector<SemanticsTree::Placed> SemanticsTree::Flatten(double input_scale) const {
  std::vector<Placed> out;
  if (!has_root()) return out;
  const double scale = input_scale > 0 && std::isfinite(input_scale) ? input_scale : 1.0;
  struct Visit {
    int32_t id;
    Transform above;
  };
  std::vector<Visit> stack = {{0, kIdentity}};
  std::unordered_set<int32_t> seen;
  while (!stack.empty()) {
    const Visit visit = stack.back();
    stack.pop_back();
    const auto found = nodes_.find(visit.id);
    if (found == nodes_.end() || !seen.insert(visit.id).second) continue;
    const Node& node = found->second;
    const Transform global = Multiply(visit.above, node.transform);
    const auto& [left, top, right, bottom] = node.rect;
    double min_x = INFINITY, min_y = INFINITY, max_x = -INFINITY, max_y = -INFINITY;
    for (const auto& [x, y] : {std::pair{left, top}, std::pair{right, top},
                               std::pair{left, bottom}, std::pair{right, bottom}}) {
      const auto [mapped_x, mapped_y] = MapPoint(global, x, y);
      min_x = std::min(min_x, mapped_x);
      min_y = std::min(min_y, mapped_y);
      max_x = std::max(max_x, mapped_x);
      max_y = std::max(max_y, mapped_y);
    }
    out.push_back({&node, min_x / scale, min_y / scale, max_x / scale, max_y / scale});
    // Pushed last first, so the first child comes out next.
    for (auto child = node.children.rbegin(); child != node.children.rend(); ++child) {
      stack.push_back({*child, global});
    }
  }
  return out;
}

}  // namespace raccoon
